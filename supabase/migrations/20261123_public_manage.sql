-- ============================================================
-- GESTIÓN PÚBLICA DEL TURNO (T-016)
-- Cancelar / reprogramar desde el link que recibe el cliente.
-- El token es una capacidad: quien lo tiene puede gestionar ESE
-- turno y nada más. No se expone ninguna tabla al anon.
-- ============================================================

ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS public_token UUID NOT NULL DEFAULT gen_random_uuid();

CREATE UNIQUE INDEX IF NOT EXISTS appointments_public_token_key
  ON public.appointments(public_token);

-- ============================================================
-- 1. Consulta del turno por token
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_public_manage_appointment(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop  public.shops;
  v_appt  public.appointments;
  v_svc   TEXT;
  v_staff TEXT;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_appt FROM public.appointments a WHERE a.public_token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shop FROM public.shops s WHERE s.id = v_appt.shop_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  SELECT c.name INTO v_svc FROM public.catalog_items c WHERE c.id = v_appt.service_id;
  SELECT st.name INTO v_staff FROM public.staff st WHERE st.id = v_appt.staff_id;

  RETURN jsonb_build_object(
    'shop', jsonb_build_object(
      'slug', v_shop.slug,
      'name', v_shop.name,
      'address', v_shop.address,
      'phone', v_shop.phone,
      'whatsapp', v_shop.whatsapp,
      'maps_url', v_shop.maps_url,
      'timezone', v_shop.timezone
    ),
    'appointment', jsonb_build_object(
      'id', v_appt.id,
      'status', v_appt.status,
      'starts_at', v_appt.starts_at,
      'ends_at', v_appt.ends_at,
      'service_id', v_appt.service_id,
      'staff_id', v_appt.staff_id,
      'service_name', v_svc,
      'staff_name', v_staff,
      'client_name', v_appt.client_name_snapshot,
      'notes', v_appt.notes,
      'can_manage', v_appt.status IN ('pending', 'confirmed') AND v_appt.starts_at > now()
    )
  );
END;
$$;

-- ============================================================
-- 2. Cancelación por el cliente
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_public_cancel_appointment(p_token UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_appt public.appointments;
BEGIN
  SELECT * INTO v_appt
    FROM public.appointments a
   WHERE a.public_token = p_token
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  IF v_appt.status IN ('cancelled', 'completed', 'no_show') THEN
    RAISE EXCEPTION 'Este turno ya no se puede cancelar.' USING ERRCODE = '22023';
  END IF;

  IF v_appt.status = 'in_progress' THEN
    RAISE EXCEPTION 'El turno ya está en curso. Hablá con el local.' USING ERRCODE = '22023';
  END IF;

  IF v_appt.starts_at <= now() THEN
    RAISE EXCEPTION 'El turno ya pasó. Hablá con el local.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.appointments
     SET status = 'cancelled',
         status_changed_at = now()
   WHERE id = v_appt.id;

  RETURN jsonb_build_object('appointment_id', v_appt.id, 'status', 'cancelled');
END;
$$;

-- ============================================================
-- 3. Reprogramación por el cliente
-- ============================================================
-- Vuelve el turno a 'pending': el local tiene que reconfirmar el
-- nuevo horario. La duración sale del servicio, no del cliente.
CREATE OR REPLACE FUNCTION public.fn_public_reschedule_appointment(
  p_token     UUID,
  p_starts_at TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_appt      public.appointments;
  v_shop      public.shops;
  v_duration  INT;
  v_ends_at   TIMESTAMPTZ;
  v_local_ts  TIMESTAMP;
  v_local_day DATE;
  v_open_ts   TIMESTAMPTZ;
  v_close_ts  TIMESTAMPTZ;
  v_diff_min  NUMERIC;
  v_svc       TEXT;
  v_staff     TEXT;
BEGIN
  IF p_token IS NULL THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_appt
    FROM public.appointments a
   WHERE a.public_token = p_token
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Turno no encontrado' USING ERRCODE = '22023';
  END IF;

  IF v_appt.status IN ('cancelled', 'completed', 'no_show') THEN
    RAISE EXCEPTION 'Este turno ya no se puede reprogramar.' USING ERRCODE = '22023';
  END IF;
  IF v_appt.status = 'in_progress' THEN
    RAISE EXCEPTION 'El turno ya está en curso. Hablá con el local.' USING ERRCODE = '22023';
  END IF;
  IF v_appt.starts_at <= now() THEN
    RAISE EXCEPTION 'El turno ya pasó. Hablá con el local.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_shop FROM public.shops s WHERE s.id = v_appt.shop_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023';
  END IF;

  IF p_starts_at IS NULL
     OR date_trunc('minute', p_starts_at) <> p_starts_at THEN
    RAISE EXCEPTION 'Horario inválido' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at < now() + interval '30 minutes' THEN
    RAISE EXCEPTION 'Elegí un horario con al menos 30 minutos de anticipación.' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at > now() + interval '90 days' THEN
    RAISE EXCEPTION 'Fecha fuera del rango permitido' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(c.duration_min, v_shop.slot_duration_min), c.name
    INTO v_duration, v_svc
    FROM public.catalog_items c
   WHERE c.id = v_appt.service_id;
  v_duration := COALESCE(v_duration, v_shop.slot_duration_min);

  SELECT st.name INTO v_staff FROM public.staff st WHERE st.id = v_appt.staff_id;
  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'Profesional no disponible' USING ERRCODE = '22023';
  END IF;

  v_ends_at   := p_starts_at + make_interval(mins => v_duration);
  v_local_ts  := p_starts_at AT TIME ZONE v_shop.timezone;
  v_local_day := v_local_ts::date;
  v_open_ts   := (v_local_day::timestamp + v_shop.open_time)  AT TIME ZONE v_shop.timezone;
  v_close_ts  := (v_local_day::timestamp + v_shop.close_time) AT TIME ZONE v_shop.timezone;

  IF p_starts_at < v_open_ts OR v_ends_at > v_close_ts THEN
    RAISE EXCEPTION 'Horario fuera de atención' USING ERRCODE = '22023';
  END IF;

  v_diff_min := extract(epoch FROM (v_local_ts::time - v_shop.open_time)) / 60;
  IF v_diff_min < 0 OR mod(v_diff_min, v_shop.slot_duration_min) <> 0 THEN
    RAISE EXCEPTION 'Horario no alineado a la grilla del local' USING ERRCODE = '22023';
  END IF;

  BEGIN
    UPDATE public.appointments
       SET starts_at = p_starts_at,
           ends_at = v_ends_at,
           status = CASE WHEN status = 'confirmed' THEN 'pending' ELSE status END,
           status_changed_at = now()
     WHERE id = v_appt.id;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Ese horario acaba de ocuparse, elegí otro'
      USING ERRCODE = '23P01';
  END;

  RETURN jsonb_build_object(
    'appointment_id', v_appt.id,
    'starts_at', p_starts_at,
    'ends_at', v_ends_at,
    'status', CASE WHEN v_appt.status = 'confirmed' THEN 'pending' ELSE v_appt.status END,
    'service_name', v_svc,
    'staff_name', v_staff,
    'shop_name', v_shop.name
  );
END;
$$;

-- ============================================================
-- 4. La reserva devuelve el token para gestionarla después
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_public_create_booking(
  p_slug          TEXT,
  p_service_id    UUID,
  p_staff_id      UUID,
  p_starts_at     TIMESTAMPTZ,
  p_client_name   TEXT,
  p_client_phone  TEXT,
  p_notes         TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop       public.shops;
  v_service    public.catalog_items;
  v_duration   INT;
  v_ends_at    TIMESTAMPTZ;
  v_local_ts   TIMESTAMP;
  v_local_day  DATE;
  v_open_ts    TIMESTAMPTZ;
  v_close_ts   TIMESTAMPTZ;
  v_diff_min   NUMERIC;
  v_name       TEXT;
  v_phone      TEXT;
  v_staff_name TEXT;
  v_client_id  UUID;
  v_appt_id    UUID;
  v_token      UUID;
  v_pending    INT;
BEGIN
  SELECT * INTO v_shop FROM public.shops WHERE slug = lower(trim(p_slug));
  IF NOT FOUND THEN RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023'; END IF;

  SELECT * INTO v_service
    FROM public.catalog_items c
   WHERE c.id = p_service_id
     AND c.shop_id = v_shop.id
     AND c.type = 'service'
     AND c.is_public AND c.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Servicio no disponible' USING ERRCODE = '22023'; END IF;

  SELECT st.name INTO v_staff_name
    FROM public.staff st
   WHERE st.id = p_staff_id AND st.shop_id = v_shop.id AND st.is_active;
  IF v_staff_name IS NULL THEN RAISE EXCEPTION 'Profesional no disponible' USING ERRCODE = '22023'; END IF;

  v_name  := btrim(COALESCE(p_client_name, ''));
  v_phone := regexp_replace(COALESCE(p_client_phone, ''), '[^0-9+]', '', 'g');
  IF char_length(v_name) < 2 OR char_length(v_name) > 80 THEN
    RAISE EXCEPTION 'Nombre inválido' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_phone) < 8 OR char_length(v_phone) > 20 THEN
    RAISE EXCEPTION 'Teléfono inválido' USING ERRCODE = '22023';
  END IF;
  IF p_notes IS NOT NULL AND char_length(p_notes) > 500 THEN
    RAISE EXCEPTION 'Notas demasiado largas' USING ERRCODE = '22023';
  END IF;

  IF date_trunc('minute', p_starts_at) <> p_starts_at THEN
    RAISE EXCEPTION 'Horario inválido' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at < now() + interval '30 minutes' THEN
    RAISE EXCEPTION 'Horario ya no disponible' USING ERRCODE = '22023';
  END IF;
  IF p_starts_at > now() + interval '90 days' THEN
    RAISE EXCEPTION 'Fecha fuera del rango permitido' USING ERRCODE = '22023';
  END IF;

  v_duration  := COALESCE(v_service.duration_min, v_shop.slot_duration_min);
  v_ends_at   := p_starts_at + make_interval(mins => v_duration);
  v_local_ts  := p_starts_at AT TIME ZONE v_shop.timezone;
  v_local_day := v_local_ts::date;
  v_open_ts   := (v_local_day::timestamp + v_shop.open_time)  AT TIME ZONE v_shop.timezone;
  v_close_ts  := (v_local_day::timestamp + v_shop.close_time) AT TIME ZONE v_shop.timezone;

  IF p_starts_at < v_open_ts OR v_ends_at > v_close_ts THEN
    RAISE EXCEPTION 'Horario fuera de atención' USING ERRCODE = '22023';
  END IF;

  v_diff_min := extract(epoch FROM (v_local_ts::time - v_shop.open_time)) / 60;
  IF v_diff_min < 0 OR mod(v_diff_min, v_shop.slot_duration_min) <> 0 THEN
    RAISE EXCEPTION 'Horario no alineado a la grilla del local' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_pending
    FROM public.appointments a
   WHERE a.shop_id = v_shop.id
     AND a.client_phone_snapshot = v_phone
     AND a.source = 'public_link'
     AND a.status IN ('pending', 'confirmed')
     AND a.starts_at > now();
  IF v_pending >= 3 THEN
    RAISE EXCEPTION 'Demasiadas reservas pendientes para este teléfono' USING ERRCODE = '22023';
  END IF;

  SELECT c.id INTO v_client_id
    FROM public.clients c
   WHERE c.shop_id = v_shop.id AND c.phone = v_phone;

  IF v_client_id IS NULL THEN
    INSERT INTO public.clients (shop_id, full_name, phone)
    VALUES (v_shop.id, v_name, v_phone)
    ON CONFLICT (shop_id, phone) DO NOTHING
    RETURNING id INTO v_client_id;

    IF v_client_id IS NULL THEN
      SELECT c.id INTO v_client_id
        FROM public.clients c
       WHERE c.shop_id = v_shop.id AND c.phone = v_phone;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.appointments (
      shop_id, client_id, staff_id, service_id,
      client_name_snapshot, client_phone_snapshot,
      starts_at, ends_at, status, source, notes
    ) VALUES (
      v_shop.id, v_client_id, p_staff_id, p_service_id,
      v_name, v_phone,
      p_starts_at, v_ends_at, 'pending', 'public_link',
      NULLIF(btrim(COALESCE(p_notes, '')), '')
    )
    RETURNING id, public_token INTO v_appt_id, v_token;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Ese horario acaba de ocuparse, elegí otro'
      USING ERRCODE = '23P01';
  END;

  RETURN jsonb_build_object(
    'appointment_id', v_appt_id,
    'public_token', v_token,
    'starts_at', p_starts_at,
    'ends_at', v_ends_at,
    'service_name', v_service.name,
    'staff_name', v_staff_name,
    'shop_name', v_shop.name,
    'status', 'pending'
  );
END;
$$;

-- ============================================================
-- 5. Grants
-- ============================================================
REVOKE ALL ON FUNCTION public.fn_public_manage_appointment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_public_cancel_appointment(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_public_reschedule_appointment(UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_public_manage_appointment(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_cancel_appointment(UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_reschedule_appointment(UUID, TIMESTAMPTZ) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO anon, authenticated;

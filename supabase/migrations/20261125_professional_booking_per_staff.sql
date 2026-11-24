-- ============================================================
-- ANSTUDIOS - Control de agendado: modo por profesional + reserva publica
-- Migracion 2026-11-25
-- Ejecutar sobre una base que ya tiene 20261123_platform_licensing.sql.
-- ============================================================

-- ============================================================
-- 1. COLUMNAS EN shops
-- ============================================================
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_book BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS professional_booking_mode TEXT NOT NULL DEFAULT 'per_staff',
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_professional_booking_mode_chk') THEN
    ALTER TABLE public.shops
      ADD CONSTRAINT shops_professional_booking_mode_chk
      CHECK (professional_booking_mode IN ('disabled', 'per_staff', 'all'));
  END IF;
END $$;

-- ============================================================
-- 2. COLUMNA EN staff
-- ============================================================
ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS can_book_appointments BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS working_days   INTEGER[],
  ADD COLUMN IF NOT EXISTS work_start_time TIME,
  ADD COLUMN IF NOT EXISTS work_end_time   TIME;

-- ============================================================
-- 3. RLS: profesional puede crear clientes/turnos segun el modo del local
-- ============================================================
DROP POLICY IF EXISTS clients_staff_insert ON public.clients;
CREATE POLICY clients_staff_insert ON public.clients
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_shop_staff(shop_id)
    AND EXISTS (
      SELECT 1
        FROM public.shops s
       WHERE s.id = shop_id
         AND (
           s.professional_booking_mode = 'all'
           OR (
             s.professional_booking_mode = 'per_staff'
             AND EXISTS (
               SELECT 1 FROM public.staff st
                WHERE st.shop_id = shop_id
                  AND st.user_id = auth.uid()
                  AND st.can_book_appointments
             )
           )
         )
    )
  );

DROP POLICY IF EXISTS appointments_staff_insert ON public.appointments;
CREATE POLICY appointments_staff_insert ON public.appointments
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_shop_staff(shop_id)
    AND staff_id = public.current_staff_id(shop_id)
    AND EXISTS (
      SELECT 1
        FROM public.shops s
       WHERE s.id = shop_id
         AND (
           s.professional_booking_mode = 'all'
           OR (
             s.professional_booking_mode = 'per_staff'
             AND EXISTS (
               SELECT 1 FROM public.staff st
                WHERE st.shop_id = shop_id
                  AND st.user_id = auth.uid()
                  AND st.can_book_appointments
             )
           )
         )
    )
  );

-- ============================================================
-- 4. CONTEXTO DEL PROFESIONAL
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_staff_context()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'staff_id', st.id,
    'staff_name', st.name,
    'staff_role', st.role,
    'staff_color', st.color_hex,
    'staff_active', st.is_active,
    'staff_photo', st.photo_url,
    'staff_bio', st.bio,
    'staff_can_book_appointments', st.can_book_appointments,
    'staff_working_days', st.working_days,
    'staff_work_start_time', st.work_start_time,
    'staff_work_end_time', st.work_end_time,
    'shop_id', s.id,
    'shop_name', s.name,
    'shop_slug', s.slug,
    'shop_address', s.address,
    'shop_phone', s.phone,
    'shop_timezone', s.timezone,
    'shop_open_time', s.open_time,
    'shop_close_time', s.close_time,
    'shop_slot_duration_min', s.slot_duration_min,
    'shop_professional_booking_mode', s.professional_booking_mode,
    'shop_public_booking_enabled', s.public_booking_enabled,
    'shop_professionals_can_manage_appointments', s.professionals_can_manage_appointments,
    'shop_professionals_can_book', (
      s.professional_booking_mode = 'all'
      OR (s.professional_booking_mode = 'per_staff' AND st.can_book_appointments)
    ),
    'shop_access', public.fn_shop_access(s.id)
  )
  FROM public.staff st
  JOIN public.shops s ON s.id = st.shop_id
  WHERE st.user_id = auth.uid()
  LIMIT 1;
$$;

-- ============================================================
-- 5. RECLAMO DE INVITACION
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_claim_staff_invite(p_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     UUID := auth.uid();
  v_code    TEXT := upper(btrim(COALESCE(p_code, '')));
  v_staff   public.staff;
  v_shop    public.shops;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;
  IF v_code !~ '^[A-Z0-9]{8}$' THEN
    RAISE EXCEPTION 'El código tiene 8 caracteres. Revisalo e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;

  SELECT st.* INTO v_staff
    FROM public.staff st
    JOIN public.staff_invites si ON si.staff_id = st.id
   WHERE si.code = v_code
     AND st.is_active
   FOR UPDATE OF st;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Código inválido o ya utilizado.' USING ERRCODE = '22023';
  END IF;

  IF v_staff.user_id = v_uid THEN
    NULL;
  ELSIF v_staff.user_id IS NOT NULL THEN
    RAISE EXCEPTION 'Ese código ya fue usado por otra cuenta.' USING ERRCODE = '22023';
  ELSIF EXISTS (
    SELECT 1 FROM public.staff st
     WHERE st.user_id = v_uid AND st.id <> v_staff.id
  ) THEN
    RAISE EXCEPTION 'Tu cuenta ya está vinculada a otro profesional.' USING ERRCODE = '22023';
  ELSIF EXISTS (
    SELECT 1 FROM public.shops s WHERE s.owner_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Esta cuenta administra un local. Usá otra cuenta para el acceso de profesional.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.staff SET user_id = v_uid WHERE id = v_staff.id;

  UPDATE public.staff_invites
     SET claimed_at = COALESCE(claimed_at, now())
   WHERE staff_id = v_staff.id;

  SELECT s.* INTO v_shop FROM public.shops s WHERE s.id = v_staff.shop_id;

  RETURN jsonb_build_object(
    'staff_id', v_staff.id,
    'staff_name', v_staff.name,
    'staff_role', v_staff.role,
    'staff_color', v_staff.color_hex,
    'shop_id', v_shop.id,
    'shop_name', v_shop.name,
    'shop_slug', v_shop.slug,
    'shop_address', v_shop.address,
    'shop_phone', v_shop.phone,
    'shop_timezone', v_shop.timezone,
    'shop_open_time', v_shop.open_time,
    'shop_close_time', v_shop.close_time,
    'shop_slot_duration_min', v_shop.slot_duration_min,
    'staff_can_book_appointments', v_staff.can_book_appointments,
    'staff_working_days', v_staff.working_days,
    'staff_work_start_time', v_staff.work_start_time,
    'staff_work_end_time', v_staff.work_end_time,
    'shop_professional_booking_mode', v_shop.professional_booking_mode,
    'shop_public_booking_enabled', v_shop.public_booking_enabled,
    'shop_professionals_can_manage_appointments', v_shop.professionals_can_manage_appointments,
    'shop_professionals_can_book', (
      v_shop.professional_booking_mode = 'all'
      OR (v_shop.professional_booking_mode = 'per_staff' AND v_staff.can_book_appointments)
    )
  );
END;
$$;

-- ============================================================
-- 6. RESERVA PUBLICA: respetar public_booking_enabled
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_public_shop(p_slug TEXT)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'shop', jsonb_build_object(
      'name', s.name,
      'slug', s.slug,
      'address', s.address,
      'phone', s.phone,
      'description', s.description,
      'whatsapp', s.whatsapp,
      'phone_landline', s.phone_landline,
      'phone_mobile', s.phone_mobile,
      'maps_url', s.maps_url,
      'photo_url', s.photo_url,
      'open_time', s.open_time,
      'close_time', s.close_time,
      'slot_duration_min', s.slot_duration_min,
      'timezone', s.timezone
    ),
    'services', COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'id', c.id, 'name', c.name, 'price', c.price, 'duration_min', c.duration_min
               ) ORDER BY c.name)
        FROM public.catalog_items c
       WHERE c.shop_id = s.id
         AND c.type = 'service'
         AND c.is_public AND c.is_active
    ), '[]'::jsonb),
    'staff', COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'id', st.id,
                 'name', st.name,
                 'color_hex', st.color_hex,
                 'photo_url', st.photo_url,
                 'bio', st.bio
               )
               ORDER BY st.name)
        FROM public.staff st
       WHERE st.shop_id = s.id AND st.is_active
    ), '[]'::jsonb)
  )
  FROM public.shops s
  WHERE s.slug = lower(trim(p_slug))
    AND public.fn_shop_usable(s.id)
    AND s.public_booking_enabled;
$$;

CREATE OR REPLACE FUNCTION public.fn_public_availability(
  p_slug       TEXT,
  p_service_id UUID,
  p_day        DATE,
  p_staff_id   UUID DEFAULT NULL
)
RETURNS TABLE (staff_id UUID, slot_start TIMESTAMPTZ, slot_end TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop     public.shops;
  v_duration INT;
  v_open_ts  TIMESTAMPTZ;
  v_close_ts TIMESTAMPTZ;
  r          RECORD;
BEGIN
  SELECT * INTO v_shop FROM public.shops WHERE slug = lower(trim(p_slug));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023';
  END IF;
  IF NOT public.fn_shop_usable(v_shop.id) THEN
    RAISE EXCEPTION 'Este local no está disponible para reservas online' USING ERRCODE = '22023';
  END IF;
  IF NOT v_shop.public_booking_enabled THEN
    RAISE EXCEPTION 'Las reservas online están desactivadas para este local' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.catalog_items c
     WHERE c.id = p_service_id
       AND c.shop_id = v_shop.id
       AND c.type = 'service'
       AND c.is_public AND c.is_active
  ) THEN
    RAISE EXCEPTION 'Servicio no disponible' USING ERRCODE = '22023';
  END IF;

  IF p_day < (now() AT TIME ZONE v_shop.timezone)::date
     OR p_day > ((now() AT TIME ZONE v_shop.timezone)::date + 90) THEN
    RAISE EXCEPTION 'Fecha fuera del rango permitido' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(c.duration_min, v_shop.slot_duration_min) INTO v_duration
    FROM public.catalog_items c
   WHERE c.id = p_service_id;

  v_open_ts  := (p_day::timestamp + v_shop.open_time)  AT TIME ZONE v_shop.timezone;
  v_close_ts := (p_day::timestamp + v_shop.close_time) AT TIME ZONE v_shop.timezone;

  FOR r IN
    SELECT st.id
      FROM public.staff st
     WHERE st.shop_id = v_shop.id
       AND st.is_active
       AND (p_staff_id IS NULL OR st.id = p_staff_id)
     ORDER BY st.name
  LOOP
    RETURN QUERY
      SELECT r.id, g.slot_start, g.slot_start + make_interval(mins => v_duration)
        FROM (
          SELECT (p_day::timestamp
                  + v_shop.open_time
                  + (n * make_interval(mins => v_shop.slot_duration_min)))
                 AT TIME ZONE v_shop.timezone AS slot_start
            FROM generate_series(0, 400) AS n
        ) g
       WHERE g.slot_start >= now() + interval '30 minutes'
         AND g.slot_start + make_interval(mins => v_duration) <= v_close_ts
         AND g.slot_start >= v_open_ts
         AND NOT EXISTS (
           SELECT 1
             FROM public.appointments a
            WHERE a.staff_id = r.id
              AND a.status IN ('pending', 'confirmed', 'in_progress')
              AND tstzrange(a.starts_at, a.ends_at, '[)')
                  && tstzrange(g.slot_start, g.slot_start + make_interval(mins => v_duration), '[)')
         )
       ORDER BY g.slot_start;
  END LOOP;
END;
$$;

-- ============================================================
-- 7. GRANTS
-- ============================================================
REVOKE ALL ON FUNCTION public.fn_staff_context() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_claim_staff_invite(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_staff_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_claim_staff_invite(TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.fn_public_shop(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_public_availability(TEXT, UUID, DATE, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_public_shop(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_availability(TEXT, UUID, DATE, UUID) TO anon, authenticated;

-- ============================================================
-- 8. RESERVA PUBLICA: bloquear creacion si esta desactivada
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
  IF NOT public.fn_shop_usable(v_shop.id) THEN
    RAISE EXCEPTION 'Este local no está disponible para reservas online' USING ERRCODE = '22023';
  END IF;
  IF NOT v_shop.public_booking_enabled THEN
    RAISE EXCEPTION 'Las reservas online están desactivadas para este local' USING ERRCODE = '22023';
  END IF;

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

REVOKE ALL ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ============================================================
-- 9. AGENDA PROPIA DEL PROFESIONAL (horarios de trabajo)
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_update_my_schedule(
  p_working_days  INTEGER[],
  p_work_start    TIME,
  p_work_end      TIME
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_days  INTEGER[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  SELECT st.* INTO v_staff FROM public.staff st WHERE st.user_id = auth.uid() LIMIT 1;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no está vinculada a un profesional.' USING ERRCODE = '42501';
  END IF;
  IF NOT v_staff.is_active THEN
    RAISE EXCEPTION 'Tu acceso está desactivado. Hablá con el local.' USING ERRCODE = '42501';
  END IF;

  IF p_working_days IS NOT NULL THEN
    SELECT array_agg(DISTINCT d) INTO v_days
      FROM unnest(p_working_days) AS d
     WHERE d BETWEEN 0 AND 6;
  END IF;

  IF v_days IS NULL OR array_length(v_days, 1) IS NULL THEN
    v_days := NULL;
  END IF;

  IF (p_work_start IS NULL) <> (p_work_end IS NULL) THEN
    RAISE EXCEPTION 'Completá ambos horarios o dejalos vacíos.' USING ERRCODE = '22023';
  END IF;
  IF p_work_start IS NOT NULL AND p_work_end IS NOT NULL AND p_work_start >= p_work_end THEN
    RAISE EXCEPTION 'El horario de inicio debe ser anterior al de fin.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.staff
     SET working_days   = v_days,
         work_start_time = p_work_start,
         work_end_time   = p_work_end
   WHERE id = v_staff.id;

  RETURN jsonb_build_object(
    'working_days', v_days,
    'work_start_time', p_work_start,
    'work_end_time', p_work_end
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_update_my_schedule(INTEGER[], TIME, TIME) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_update_my_schedule(INTEGER[], TIME, TIME) TO authenticated;

-- ============================================================
-- 10. DISPONIBILIDAD PUBLICA POR PROFESIONAL
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_public_availability(
  p_slug       TEXT,
  p_service_id UUID,
  p_day        DATE,
  p_staff_id   UUID DEFAULT NULL
)
RETURNS TABLE (staff_id UUID, slot_start TIMESTAMPTZ, slot_end TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop     public.shops;
  v_duration INT;
  v_open_ts  TIMESTAMPTZ;
  v_close_ts TIMESTAMPTZ;
  r          RECORD;
  v_day_dow  INT := extract(dow FROM p_day)::INT;
  v_staff_open  TIME;
  v_staff_close TIME;
  v_staff_days  INTEGER[];
BEGIN
  SELECT * INTO v_shop FROM public.shops WHERE slug = lower(trim(p_slug));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023';
  END IF;
  IF NOT public.fn_shop_usable(v_shop.id) THEN
    RAISE EXCEPTION 'Este local no está disponible para reservas online' USING ERRCODE = '22023';
  END IF;
  IF NOT v_shop.public_booking_enabled THEN
    RAISE EXCEPTION 'Las reservas online están desactivadas para este local' USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.catalog_items c
     WHERE c.id = p_service_id
       AND c.shop_id = v_shop.id
       AND c.type = 'service'
       AND c.is_public AND c.is_active
  ) THEN
    RAISE EXCEPTION 'Servicio no disponible' USING ERRCODE = '22023';
  END IF;

  IF p_day < (now() AT TIME ZONE v_shop.timezone)::date
     OR p_day > ((now() AT TIME ZONE v_shop.timezone)::date + 90) THEN
    RAISE EXCEPTION 'Fecha fuera del rango permitido' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(c.duration_min, v_shop.slot_duration_min) INTO v_duration
    FROM public.catalog_items c
   WHERE c.id = p_service_id;

  v_open_ts  := (p_day::timestamp + v_shop.open_time)  AT TIME ZONE v_shop.timezone;
  v_close_ts := (p_day::timestamp + v_shop.close_time) AT TIME ZONE v_shop.timezone;

  FOR r IN
    SELECT st.id, st.working_days, st.work_start_time, st.work_end_time
      FROM public.staff st
     WHERE st.shop_id = v_shop.id
       AND st.is_active
       AND (p_staff_id IS NULL OR st.id = p_staff_id)
     ORDER BY st.name
  LOOP
    v_staff_days := r.working_days;
    IF v_staff_days IS NOT NULL AND NOT (v_day_dow = ANY(v_staff_days)) THEN
      CONTINUE;
    END IF;

    v_staff_open  := COALESCE(r.work_start_time, v_shop.open_time);
    v_staff_close := COALESCE(r.work_end_time, v_shop.close_time);

    RETURN QUERY
      SELECT r.id, g.slot_start, g.slot_start + make_interval(mins => v_duration)
        FROM (
          SELECT (p_day::timestamp
                  + v_staff_open
                  + (n * make_interval(mins => v_shop.slot_duration_min)))
                 AT TIME ZONE v_shop.timezone AS slot_start
            FROM generate_series(0, 400) AS n
        ) g
       WHERE g.slot_start >= now() + interval '30 minutes'
         AND g.slot_start + make_interval(mins => v_duration) <= (p_day::timestamp + v_staff_close) AT TIME ZONE v_shop.timezone
         AND g.slot_start >= (p_day::timestamp + v_staff_open) AT TIME ZONE v_shop.timezone
         AND g.slot_start >= v_open_ts
         AND NOT EXISTS (
           SELECT 1
             FROM public.appointments a
            WHERE a.staff_id = r.id
              AND a.status IN ('pending', 'confirmed', 'in_progress')
              AND tstzrange(a.starts_at, a.ends_at, '[)')
                  && tstzrange(g.slot_start, g.slot_start + make_interval(mins => v_duration), '[)')
         )
       ORDER BY g.slot_start;
  END LOOP;
END;
$$;

-- ============================================================
-- 11. REASIGNACION / REPROGRAMACION DE TURNO
-- ============================================================
CREATE POLICY appointments_staff_update ON public.appointments
  FOR UPDATE TO authenticated
  USING (
    public.is_shop_staff(shop_id)
    AND (
      public.is_shop_owner(shop_id)
      OR (
        (SELECT s.professionals_can_manage_appointments FROM public.shops s WHERE s.id = shop_id)
        AND EXISTS (SELECT 1 FROM public.staff st WHERE st.shop_id = shop_id AND st.user_id = auth.uid())
      )
    )
  )
  WITH CHECK (
    public.is_shop_staff(shop_id)
    AND (
      public.is_shop_owner(shop_id)
      OR (
        (SELECT s.professionals_can_manage_appointments FROM public.shops s WHERE s.id = shop_id)
        AND EXISTS (SELECT 1 FROM public.staff st WHERE st.shop_id = shop_id AND st.user_id = auth.uid())
      )
    )
  );

CREATE OR REPLACE FUNCTION public.fn_reassign_appointment(
  p_appointment_id UUID,
  p_new_staff_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_appt  public.appointments;
  v_shop  public.shops;
  v_new   public.staff;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  SELECT st.* INTO v_staff FROM public.staff st WHERE st.user_id = auth.uid() LIMIT 1;
  IF v_staff.id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.shops s WHERE s.owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'No tenés permiso.' USING ERRCODE = '42501';
  END IF;

  SELECT a.* INTO v_appt FROM public.appointments a WHERE a.id = p_appointment_id FOR UPDATE;
  IF v_appt.id IS NULL THEN
    RAISE EXCEPTION 'Turno inexistente' USING ERRCODE = '22023';
  END IF;

  SELECT s.* INTO v_shop FROM public.shops s WHERE s.id = v_appt.shop_id;
  IF v_shop.id IS NULL THEN
    RAISE EXCEPTION 'Local inexistente' USING ERRCODE = '22023';
  END IF;

  IF v_staff.id IS NOT NULL AND v_staff.shop_id <> v_shop.id THEN
    RAISE EXCEPTION 'No tenés permiso.' USING ERRCODE = '42501';
  END IF;

  IF v_staff.id IS NOT NULL
     AND v_staff.id <> v_appt.staff_id
     AND NOT v_shop.professionals_can_manage_appointments THEN
    RAISE EXCEPTION 'El dueño no habilitó la gestión de turnos.' USING ERRCODE = '42501';
  END IF;

  SELECT st.* INTO v_new FROM public.staff st
   WHERE st.id = p_new_staff_id AND st.shop_id = v_shop.id AND st.is_active;
  IF v_new.id IS NULL THEN
    RAISE EXCEPTION 'Profesional no disponible' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.appointments a
     WHERE a.staff_id = p_new_staff_id
       AND a.id <> v_appt.id
       AND a.status IN ('pending', 'confirmed', 'in_progress')
       AND tstzrange(a.starts_at, a.ends_at, '[)')
           && tstzrange(v_appt.starts_at, v_appt.ends_at, '[)')
  ) THEN
    RAISE EXCEPTION 'Ese profesional ya tiene un turno en ese horario.' USING ERRCODE = '23P01';
  END IF;

  UPDATE public.appointments
     SET staff_id = p_new_staff_id
   WHERE id = v_appt.id;

  RETURN jsonb_build_object('appointment_id', v_appt.id, 'staff_id', p_new_staff_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_reschedule_appointment_internal(
  p_appointment_id UUID,
  p_new_starts_at  TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_appt  public.appointments;
  v_shop  public.shops;
  v_svc   public.catalog_items;
  v_duration INT;
  v_ends_at  TIMESTAMPTZ;
  v_local_ts TIMESTAMP;
  v_local_day DATE;
  v_open_ts TIMESTAMPTZ;
  v_close_ts TIMESTAMPTZ;
  v_diff_min NUMERIC;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  SELECT st.* INTO v_staff FROM public.staff st WHERE st.user_id = auth.uid() LIMIT 1;
  IF v_staff.id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.shops s WHERE s.owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'No tenés permiso.' USING ERRCODE = '42501';
  END IF;

  SELECT a.* INTO v_appt FROM public.appointments a WHERE a.id = p_appointment_id FOR UPDATE;
  IF v_appt.id IS NULL THEN
    RAISE EXCEPTION 'Turno inexistente' USING ERRCODE = '22023';
  END IF;

  SELECT s.* INTO v_shop FROM public.shops s WHERE s.id = v_appt.shop_id;
  IF v_shop.id IS NULL THEN
    RAISE EXCEPTION 'Local inexistente' USING ERRCODE = '22023';
  END IF;

  IF v_staff.id IS NOT NULL AND v_staff.shop_id <> v_shop.id THEN
    RAISE EXCEPTION 'No tenés permiso.' USING ERRCODE = '42501';
  END IF;

  IF v_staff.id IS NOT NULL
     AND v_staff.id <> v_appt.staff_id
     AND NOT v_shop.professionals_can_manage_appointments THEN
    RAISE EXCEPTION 'El dueño no habilitó la gestión de turnos.' USING ERRCODE = '42501';
  END IF;

  IF p_new_starts_at IS NULL
     OR date_trunc('minute', p_new_starts_at) <> p_new_starts_at THEN
    RAISE EXCEPTION 'Horario inválido' USING ERRCODE = '22023';
  END IF;
  IF p_new_starts_at < now() + interval '30 minutes' THEN
    RAISE EXCEPTION 'Elegí un horario con al menos 30 minutos de anticipación.' USING ERRCODE = '22023';
  END IF;
  IF p_new_starts_at > now() + interval '90 days' THEN
    RAISE EXCEPTION 'Fecha fuera del rango permitido' USING ERRCODE = '22023';
  END IF;

  SELECT c.* INTO v_svc FROM public.catalog_items c WHERE c.id = v_appt.service_id;
  v_duration := COALESCE(v_svc.duration_min, v_shop.slot_duration_min);
  v_ends_at := p_new_starts_at + make_interval(mins => v_duration);
  v_local_ts := p_new_starts_at AT TIME ZONE v_shop.timezone;
  v_local_day := v_local_ts::date;
  v_open_ts := (v_local_day::timestamp + v_shop.open_time) AT TIME ZONE v_shop.timezone;
  v_close_ts := (v_local_day::timestamp + v_shop.close_time) AT TIME ZONE v_shop.timezone;

  IF p_new_starts_at < v_open_ts OR v_ends_at > v_close_ts THEN
    RAISE EXCEPTION 'Horario fuera de atención' USING ERRCODE = '22023';
  END IF;

  v_diff_min := extract(epoch FROM (v_local_ts::time - v_shop.open_time)) / 60;
  IF v_diff_min < 0 OR mod(v_diff_min, v_shop.slot_duration_min) <> 0 THEN
    RAISE EXCEPTION 'Horario no alineado a la grilla del local' USING ERRCODE = '22023';
  END IF;

  BEGIN
    UPDATE public.appointments
       SET starts_at = p_new_starts_at,
           ends_at = v_ends_at,
           status = CASE WHEN status = 'confirmed' THEN 'pending' ELSE status END,
           status_changed_at = now()
     WHERE id = v_appt.id;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Ese horario acaba de ocuparse, elegí otro' USING ERRCODE = '23P01';
  END;

  RETURN jsonb_build_object(
    'appointment_id', v_appt.id,
    'starts_at', p_new_starts_at,
    'ends_at', v_ends_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_reassign_appointment(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_reschedule_appointment_internal(UUID, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_reassign_appointment(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_reschedule_appointment_internal(UUID, TIMESTAMPTZ) TO authenticated;

-- ============================================================
-- 12. FIX: productos con duración 0 (catalog_items)
-- ============================================================
ALTER TABLE public.catalog_items
  DROP CONSTRAINT IF EXISTS catalog_items_duration_min_check;

ALTER TABLE public.catalog_items
  ADD CONSTRAINT catalog_items_duration_min_check
  CHECK (duration_min = 0 OR duration_min BETWEEN 5 AND 480);

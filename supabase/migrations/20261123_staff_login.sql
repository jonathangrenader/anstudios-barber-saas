-- ============================================================
-- T-011: LOGIN DE PROFESIONALES
-- Migración incremental para bases que ya tienen el esquema T-000.
-- El dueño comparte un código de 8 caracteres; el profesional se registra con
-- email/contraseña e ingresa el código una sola vez. La ficha queda vinculada
-- por staff.user_id y puede consultar únicamente su propia agenda.
-- Los códigos viven en una tabla aparte para que el roster del equipo (visible
-- para otros profesionales) no los exponga.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.staff_invites (
  staff_id   UUID PRIMARY KEY REFERENCES public.staff(id) ON DELETE CASCADE,
  shop_id    UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  code       TEXT NOT NULL UNIQUE
             DEFAULT upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
             CHECK (code ~ '^[A-Z0-9]{8}$'),
  claimed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_invites_shop ON public.staff_invites (shop_id);

ALTER TABLE public.staff_invites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_invites_owner_all ON public.staff_invites;
CREATE POLICY staff_invites_owner_all ON public.staff_invites
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

-- Sin política para profesionales: solo el dueño ve los códigos.
REVOKE ALL ON public.staff_invites FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.staff_invites TO authenticated;

-- Invitación por cada ficha del equipo (incluye las creadas antes de esta migración).
INSERT INTO public.staff_invites (staff_id, shop_id)
SELECT st.id, st.shop_id
  FROM public.staff st
 WHERE NOT EXISTS (
   SELECT 1 FROM public.staff_invites si WHERE si.staff_id = st.id
 )
ON CONFLICT (staff_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.fn_staff_invite_create()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.staff_invites (staff_id, shop_id)
  VALUES (NEW.id, NEW.shop_id)
  ON CONFLICT (staff_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_staff_invite_create ON public.staff;
CREATE TRIGGER trg_staff_invite_create
  AFTER INSERT ON public.staff
  FOR EACH ROW EXECUTE FUNCTION public.fn_staff_invite_create();

-- Código nuevo (y desvincula la cuenta actual, si había una).
CREATE OR REPLACE FUNCTION public.fn_refresh_staff_invite(p_staff_id UUID)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop_id UUID;
  v_code TEXT;
BEGIN
  SELECT st.shop_id INTO v_shop_id
    FROM public.staff st
   WHERE st.id = p_staff_id;

  IF v_shop_id IS NULL THEN
    RAISE EXCEPTION 'Profesional inexistente' USING ERRCODE = '22023';
  END IF;
  IF NOT public.is_shop_owner(v_shop_id) THEN
    RAISE EXCEPTION 'Solo el dueño puede generar códigos de acceso' USING ERRCODE = '42501';
  END IF;

  UPDATE public.staff_invites
     SET code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
         claimed_at = NULL
   WHERE staff_id = p_staff_id
  RETURNING code INTO v_code;

  IF v_code IS NULL THEN
    INSERT INTO public.staff_invites (staff_id, shop_id)
    VALUES (p_staff_id, v_shop_id)
    RETURNING code INTO v_code;
  END IF;

  UPDATE public.staff SET user_id = NULL WHERE id = p_staff_id;
  RETURN v_code;
END;
$$;

-- Desvincula la cuenta y rota el código para que la cuenta anterior no vuelva a entrar.
CREATE OR REPLACE FUNCTION public.fn_unlink_staff_access(p_staff_id UUID)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public.fn_refresh_staff_invite(p_staff_id);
END;
$$;

-- El profesional ingresa el código y queda vinculado a su ficha.
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
    NULL; -- ya estaba vinculado: idempotente
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
    'shop_close_time', v_shop.close_time
  );
END;
$$;

-- Contexto del profesional logueado (local + ficha propia). NULL si no tiene ficha.
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
    'shop_id', s.id,
    'shop_name', s.name,
    'shop_slug', s.slug,
    'shop_address', s.address,
    'shop_phone', s.phone,
    'shop_timezone', s.timezone,
    'shop_open_time', s.open_time,
    'shop_close_time', s.close_time
  )
  FROM public.staff st
  JOIN public.shops s ON s.id = st.shop_id
  WHERE st.user_id = auth.uid()
  LIMIT 1;
$$;

-- Agenda del día del profesional logueado, calculada en la zona del local.
CREATE OR REPLACE FUNCTION public.fn_my_agenda(p_date DATE)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_tz    TEXT;
  v_start TIMESTAMPTZ;
  v_end   TIMESTAMPTZ;
  v_rows  JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  SELECT st.* INTO v_staff
    FROM public.staff st
   WHERE st.user_id = auth.uid()
   LIMIT 1;

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no está vinculada a un profesional.' USING ERRCODE = '42501';
  END IF;
  IF NOT v_staff.is_active THEN
    RAISE EXCEPTION 'Tu acceso está desactivado. Hablá con el local.' USING ERRCODE = '42501';
  END IF;

  SELECT s.timezone INTO v_tz FROM public.shops s WHERE s.id = v_staff.shop_id;

  v_start := (p_date::timestamp AT TIME ZONE v_tz);
  v_end   := ((p_date + 1)::timestamp AT TIME ZONE v_tz);

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', a.id,
        'starts_at', a.starts_at,
        'ends_at', a.ends_at,
        'status', a.status,
        'source', a.source,
        'reminder_sent', a.reminder_sent,
        'notes', a.notes,
        'client_name', a.client_name_snapshot,
        'client_phone', a.client_phone_snapshot,
        'service_name', ci.name
      )
      ORDER BY a.starts_at
    ),
    '[]'::jsonb
  )
  INTO v_rows
  FROM public.appointments a
  LEFT JOIN public.catalog_items ci ON ci.id = a.service_id
  WHERE a.staff_id = v_staff.id
    AND a.starts_at >= v_start
    AND a.starts_at <  v_end
    AND a.status <> 'cancelled';

  RETURN v_rows;
END;
$$;

-- ============================================================
-- Grants de las funciones de acceso
-- ============================================================
REVOKE ALL ON FUNCTION public.fn_refresh_staff_invite(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_unlink_staff_access(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_claim_staff_invite(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_staff_context() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_my_agenda(DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_refresh_staff_invite(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_unlink_staff_access(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_claim_staff_invite(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_staff_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_my_agenda(DATE) TO authenticated;

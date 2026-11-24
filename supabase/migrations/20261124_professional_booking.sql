-- ============================================================
-- ANSTUDIOS - Permiso del dueño para que los profesionales agenden turnos
-- Migración 2026-11-24
-- Ejecutar sobre una base que ya tiene 20261123_platform_licensing.sql.
-- ============================================================

-- ============================================================
-- 1. SETTING DEL LOCAL
-- ============================================================
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_book BOOLEAN NOT NULL DEFAULT false;

-- ============================================================
-- 2. RLS: el profesional puede crear clientes y turnos propios
--    solo si el dueño habilitó el permiso.
-- ============================================================
DROP POLICY IF EXISTS clients_staff_insert ON public.clients;
CREATE POLICY clients_staff_insert ON public.clients
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_shop_staff(shop_id)
    AND EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id = shop_id AND s.professionals_can_book
    )
  );

DROP POLICY IF EXISTS appointments_staff_insert ON public.appointments;
CREATE POLICY appointments_staff_insert ON public.appointments
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_shop_staff(shop_id)
    AND staff_id = public.current_staff_id(shop_id)
    AND EXISTS (
      SELECT 1 FROM public.shops s
       WHERE s.id = shop_id AND s.professionals_can_book
    )
  );

-- ============================================================
-- 3. CONTEXTO DEL PROFESIONAL: incluir el permiso y la duración base
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
    'shop_id', s.id,
    'shop_name', s.name,
    'shop_slug', s.slug,
    'shop_address', s.address,
    'shop_phone', s.phone,
    'shop_timezone', s.timezone,
    'shop_open_time', s.open_time,
    'shop_close_time', s.close_time,
    'shop_slot_duration_min', s.slot_duration_min,
    'shop_professionals_can_book', s.professionals_can_book,
    'shop_access', public.fn_shop_access(s.id)
  )
  FROM public.staff st
  JOIN public.shops s ON s.id = st.shop_id
  WHERE st.user_id = auth.uid()
  LIMIT 1;
$$;

-- El reclamo del código también devuelve el permiso y la duración.
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
    'shop_professionals_can_book', v_shop.professionals_can_book
  );
END;
$$;

REVOKE ALL ON FUNCTION public.fn_staff_context() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_claim_staff_invite(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_staff_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_claim_staff_invite(TEXT) TO authenticated;

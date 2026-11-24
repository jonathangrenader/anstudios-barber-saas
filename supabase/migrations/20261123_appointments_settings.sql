-- ============================================================
-- ANSTUDIOS - Migración 2026-11-23
-- Estados de turno por profesional, visitas de clientes,
-- perfil del salón, fotos y Storage para imágenes.
-- Ejecutar sobre una base que ya tiene 20261123_staff_login.sql.
-- ============================================================

-- ============================================================
-- 1. CAMPOS NUEVOS
-- ============================================================
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS description    TEXT,
  ADD COLUMN IF NOT EXISTS whatsapp       TEXT,
  ADD COLUMN IF NOT EXISTS phone_landline TEXT,
  ADD COLUMN IF NOT EXISTS phone_mobile   TEXT,
  ADD COLUMN IF NOT EXISTS maps_url       TEXT,
  ADD COLUMN IF NOT EXISTS photo_url      TEXT;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS photo_url TEXT,
  ADD COLUMN IF NOT EXISTS bio       TEXT;

ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS status_changed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS status_changed_at TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_description_len') THEN
    ALTER TABLE public.shops ADD CONSTRAINT shops_description_len
      CHECK (description IS NULL OR char_length(description) <= 600);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'staff_bio_len') THEN
    ALTER TABLE public.staff ADD CONSTRAINT staff_bio_len
      CHECK (bio IS NULL OR char_length(bio) <= 240);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_photo_url_len') THEN
    ALTER TABLE public.shops ADD CONSTRAINT shops_photo_url_len
      CHECK (photo_url IS NULL OR char_length(photo_url) <= 500);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'staff_photo_url_len') THEN
    ALTER TABLE public.staff ADD CONSTRAINT staff_photo_url_len
      CHECK (photo_url IS NULL OR char_length(photo_url) <= 500);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_maps_url_len') THEN
    ALTER TABLE public.shops ADD CONSTRAINT shops_maps_url_len
      CHECK (maps_url IS NULL OR char_length(maps_url) <= 500);
  END IF;
END $$;

-- ============================================================
-- 2. ESTADOS DE TURNO DESDE EL ACCESO DE PROFESIONAL
-- ============================================================
-- Solo el profesional dueño del turno puede moverlo. La comisión
-- sigue naciendo al cobrar en caja: esto no genera dinero.
CREATE OR REPLACE FUNCTION public.fn_set_my_appointment_status(
  p_appointment_id UUID,
  p_status         TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff   public.staff;
  v_appt    public.appointments;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  IF p_status NOT IN ('in_progress', 'completed', 'no_show') THEN
    RAISE EXCEPTION 'Estado no permitido' USING ERRCODE = '22023';
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

  SELECT a.* INTO v_appt
    FROM public.appointments a
   WHERE a.id = p_appointment_id
     AND a.staff_id = v_staff.id
   FOR UPDATE;

  IF v_appt.id IS NULL THEN
    RAISE EXCEPTION 'Ese turno no es tuyo.' USING ERRCODE = '42501';
  END IF;

  IF v_appt.status = p_status THEN
    RETURN jsonb_build_object('id', v_appt.id, 'status', v_appt.status);
  END IF;

  IF v_appt.status = 'cancelled' THEN
    RAISE EXCEPTION 'El turno está cancelado.' USING ERRCODE = '22023';
  END IF;

  IF p_status = 'in_progress'
     AND v_appt.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'Solo podés iniciar un turno pendiente o confirmado.' USING ERRCODE = '22023';
  END IF;

  IF p_status = 'completed'
     AND v_appt.status <> 'in_progress' THEN
    RAISE EXCEPTION 'Primero tenés que iniciar el turno.' USING ERRCODE = '22023';
  END IF;

  IF p_status = 'no_show'
     AND v_appt.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'Solo podés marcar como ausente un turno pendiente o confirmado.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.appointments
     SET status = p_status,
         status_changed_by = auth.uid(),
         status_changed_at = now()
   WHERE id = v_appt.id
   RETURNING * INTO v_appt;

  RETURN jsonb_build_object('id', v_appt.id, 'status', v_appt.status);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_set_my_appointment_status(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_set_my_appointment_status(UUID, TEXT) TO authenticated;

-- ============================================================
-- 3. VISITAS DEL CLIENTE (last_visit_at / total_visits)
-- ============================================================
-- La base es la única fuente: se recalcula al completar o revertir
-- un turno, sin importar desde qué dispositivo se hizo.
CREATE OR REPLACE FUNCTION public.fn_sync_client_visits()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_client UUID;
BEGIN
  v_client := COALESCE(NEW.client_id, OLD.client_id);
  IF v_client IS NULL THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  UPDATE public.clients c
     SET total_visits = (
           SELECT count(*) FROM public.appointments a
            WHERE a.client_id = v_client AND a.status = 'completed'
         ),
         last_visit_at = (
           SELECT max(a.starts_at) FROM public.appointments a
            WHERE a.client_id = v_client AND a.status = 'completed'
         )
   WHERE c.id = v_client;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_appointments_client_visits ON public.appointments;
CREATE TRIGGER trg_appointments_client_visits
  AFTER UPDATE OF status ON public.appointments
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.fn_sync_client_visits();

-- Backfill de los datos existentes.
UPDATE public.clients c
   SET total_visits = v.total,
       last_visit_at = v.last_visit
  FROM (
    SELECT a.client_id,
           count(*) AS total,
           max(a.starts_at) AS last_visit
      FROM public.appointments a
     WHERE a.status = 'completed' AND a.client_id IS NOT NULL
     GROUP BY a.client_id
  ) v
 WHERE c.id = v.client_id
   AND (c.total_visits IS DISTINCT FROM v.total OR c.last_visit_at IS DISTINCT FROM v.last_visit);

UPDATE public.clients c
   SET total_visits = 0,
       last_visit_at = NULL
 WHERE c.total_visits > 0
   AND NOT EXISTS (
     SELECT 1 FROM public.appointments a
      WHERE a.client_id = c.id AND a.status = 'completed'
   );

-- ============================================================
-- 4. PERFIL DEL PROFESIONAL (foto y descripción)
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_update_my_profile(
  p_photo_url TEXT,
  p_bio       TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_bio   TEXT;
  v_photo TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Tenés que iniciar sesión' USING ERRCODE = '28000';
  END IF;

  SELECT st.* INTO v_staff FROM public.staff st WHERE st.user_id = auth.uid() LIMIT 1;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no está vinculada a un profesional.' USING ERRCODE = '42501';
  END IF;

  v_photo := NULLIF(btrim(COALESCE(p_photo_url, '')), '');
  v_bio   := NULLIF(btrim(COALESCE(p_bio, '')), '');

  IF v_photo IS NOT NULL AND (v_photo !~ '^https?://' OR char_length(v_photo) > 500) THEN
    RAISE EXCEPTION 'La foto no es válida.' USING ERRCODE = '22023';
  END IF;
  IF v_bio IS NOT NULL AND char_length(v_bio) > 240 THEN
    RAISE EXCEPTION 'La descripción admite hasta 240 caracteres.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.staff
     SET photo_url = v_photo,
         bio = v_bio
   WHERE id = v_staff.id;

  RETURN jsonb_build_object('photo_url', v_photo, 'bio', v_bio);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_update_my_profile(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_update_my_profile(TEXT, TEXT) TO authenticated;

-- ============================================================
-- 5. CONTEXTO DEL PROFESIONAL CON PERFIL
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
    'shop_close_time', s.close_time
  )
  FROM public.staff st
  JOIN public.shops s ON s.id = st.shop_id
  WHERE st.user_id = auth.uid()
  LIMIT 1;
$$;

-- ============================================================
-- 6. DATOS PÚBLICOS CON PERFIL DEL SALÓN Y DEL PROFESIONAL
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
  WHERE s.slug = lower(trim(p_slug));
$$;

-- ============================================================
-- 7. STORAGE DE IMÁGENES (bucket público `media`)
-- ============================================================
INSERT INTO storage.buckets (id, name, public)
VALUES ('media', 'media', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS media_owner_insert ON storage.objects;
DROP POLICY IF EXISTS media_owner_update ON storage.objects;
DROP POLICY IF EXISTS media_owner_delete ON storage.objects;
DROP POLICY IF EXISTS media_staff_insert ON storage.objects;
DROP POLICY IF EXISTS media_staff_update ON storage.objects;
DROP POLICY IF EXISTS media_staff_delete ON storage.objects;

-- Dueño: shops/<shop_id>/...
CREATE POLICY media_owner_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'shops'
  AND public.is_shop_owner(((storage.foldername(name))[2])::uuid)
);
CREATE POLICY media_owner_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'shops'
  AND public.is_shop_owner(((storage.foldername(name))[2])::uuid)
)
WITH CHECK (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'shops'
  AND public.is_shop_owner(((storage.foldername(name))[2])::uuid)
);
CREATE POLICY media_owner_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'shops'
  AND public.is_shop_owner(((storage.foldername(name))[2])::uuid)
);

-- Profesional: staff/<staff_id>/... (solo su propia ficha)
CREATE POLICY media_staff_insert ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'staff'
  AND EXISTS (
    SELECT 1 FROM public.staff st
     WHERE st.id::text = (storage.foldername(name))[2]
       AND st.user_id = auth.uid()
  )
);
CREATE POLICY media_staff_update ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'staff'
  AND EXISTS (
    SELECT 1 FROM public.staff st
     WHERE st.id::text = (storage.foldername(name))[2]
       AND st.user_id = auth.uid()
  )
)
WITH CHECK (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'staff'
  AND EXISTS (
    SELECT 1 FROM public.staff st
     WHERE st.id::text = (storage.foldername(name))[2]
       AND st.user_id = auth.uid()
  )
);
CREATE POLICY media_staff_delete ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'media'
  AND (storage.foldername(name))[1] = 'staff'
  AND EXISTS (
    SELECT 1 FROM public.staff st
     WHERE st.id::text = (storage.foldername(name))[2]
       AND st.user_id = auth.uid()
  )
);

-- ============================================================
-- 8. GRANTS
-- ============================================================
GRANT EXECUTE ON FUNCTION public.fn_staff_context() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_shop(TEXT) TO anon, authenticated;

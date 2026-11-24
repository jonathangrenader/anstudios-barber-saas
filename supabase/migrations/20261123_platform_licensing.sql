-- ============================================================
-- ANSTUDIOS - Licencias de local: suspension, prueba y superadmin
-- Migracion 2026-11-23 (T-022)
-- Ejecutar sobre una base que ya tiene 20261123_calendar_feed.sql.
-- ============================================================

-- ============================================================
-- 1. ESTADO DE LICENCIA DEL LOCAL
-- ============================================================
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS is_suspended   BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS suspended_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS suspension_note TEXT,
  ADD COLUMN IF NOT EXISTS trial_ends_at  TIMESTAMPTZ;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shops_suspension_note_len') THEN
    ALTER TABLE public.shops ADD CONSTRAINT shops_suspension_note_len
      CHECK (suspension_note IS NULL OR char_length(suspension_note) <= 200);
  END IF;
END $$;

-- El dueño no puede quitarse la suspensión ni regalarse una prueba por API.
-- (La función es invoker a propósito: "authenticated" es el JWT del cliente;
--  service_role y el SQL Editor quedan habilitados para operación manual.)
CREATE OR REPLACE FUNCTION public.fn_shops_guard_license()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF (NEW.is_suspended, NEW.suspended_at, NEW.suspension_note, NEW.trial_ends_at)
     IS DISTINCT FROM (OLD.is_suspended, OLD.suspended_at, OLD.suspension_note, OLD.trial_ends_at)
     AND current_user = 'authenticated'
     AND NOT public.fn_is_platform_admin()
  THEN
    RAISE EXCEPTION 'Solo ANSTUDIOS puede cambiar la licencia del local' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_shops_guard_license ON public.shops;
CREATE TRIGGER trg_shops_guard_license
  BEFORE UPDATE ON public.shops
  FOR EACH ROW EXECUTE FUNCTION public.fn_shops_guard_license();

-- ============================================================
-- 2. SUPERADMINISTRADORES DE LA PLATAFORMA
-- Sin politicas RLS: solo se consulta desde funciones SECURITY DEFINER.
-- Alta manual (SQL Editor):
--   INSERT INTO public.platform_admins (user_id)
--   SELECT id FROM auth.users WHERE email = 'tu@email.com'
--   ON CONFLICT DO NOTHING;
-- ============================================================
CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.platform_admins FROM anon, authenticated;

-- ============================================================
-- 3. ESTADO EFECTIVO DE ACCESO
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_shop_usable(p_shop_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.shops s
     WHERE s.id = p_shop_id
       AND NOT s.is_suspended
       AND (s.trial_ends_at IS NULL OR s.trial_ends_at > now())
  );
$$;

CREATE OR REPLACE FUNCTION public.fn_shop_access(p_shop_id UUID)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'state', CASE
      WHEN s.is_suspended THEN 'suspended'
      WHEN s.trial_ends_at IS NOT NULL AND s.trial_ends_at <= now() THEN 'trial_expired'
      WHEN s.trial_ends_at IS NOT NULL THEN 'trial'
      ELSE 'active'
    END,
    'trial_ends_at', s.trial_ends_at,
    'days_left', CASE
      WHEN s.trial_ends_at IS NOT NULL AND s.trial_ends_at > now()
        THEN ceil(extract(epoch FROM (s.trial_ends_at - now())) / 86400)::INT
      ELSE 0
    END,
    'suspended_at', s.suspended_at,
    'suspension_note', s.suspension_note
  )
  FROM public.shops s
  WHERE s.id = p_shop_id;
$$;

-- ============================================================
-- 4. FUNCIONES DEL PANEL DE PLATAFORMA
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_is_platform_admin()
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.fn_platform_me()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'is_admin', public.fn_is_platform_admin(),
    'has_shop', EXISTS (SELECT 1 FROM public.shops s WHERE s.owner_id = auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.fn_platform_shops()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.fn_is_platform_admin() THEN
    RAISE EXCEPTION 'Solo el administrador de la plataforma' USING ERRCODE = '42501';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(row_data ORDER BY suspended DESC, created_at DESC)
      FROM (
        SELECT
          jsonb_build_object(
            'id', s.id,
            'name', s.name,
            'slug', s.slug,
            'address', s.address,
            'created_at', s.created_at,
            'owner_email', au.email,
            'is_suspended', s.is_suspended,
            'suspended_at', s.suspended_at,
            'suspension_note', s.suspension_note,
            'trial_ends_at', s.trial_ends_at,
            'staff_count', (
              SELECT count(*) FROM public.staff st WHERE st.shop_id = s.id
            ),
            'appointments_count', (
              SELECT count(*) FROM public.appointments a WHERE a.shop_id = s.id
            ),
            'last_appointment_at', (
              SELECT max(a.starts_at) FROM public.appointments a WHERE a.shop_id = s.id
            ),
            'is_mine', s.owner_id = auth.uid()
          ) AS row_data,
          s.is_suspended AS suspended,
          s.created_at AS created_at
        FROM public.shops s
        JOIN auth.users au ON au.id = s.owner_id
      ) t
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_platform_set_suspension(
  p_shop_id   UUID,
  p_suspended BOOLEAN,
  p_note      TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  IF NOT public.fn_is_platform_admin() THEN
    RAISE EXCEPTION 'Solo el administrador de la plataforma' USING ERRCODE = '42501';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 200 THEN
    RAISE EXCEPTION 'La nota no puede superar los 200 caracteres' USING ERRCODE = '22023';
  END IF;

  UPDATE public.shops
     SET is_suspended = p_suspended,
         suspended_at = CASE
           WHEN p_suspended THEN COALESCE(suspended_at, now())
           ELSE NULL
         END,
         suspension_note = CASE WHEN p_suspended THEN v_note ELSE NULL END
   WHERE id = p_shop_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local inexistente' USING ERRCODE = '22023';
  END IF;

  RETURN public.fn_shop_access(p_shop_id);
END;
$$;

-- p_days = 0 quita la prueba; 1..365 otorga/renueva desde ahora.
CREATE OR REPLACE FUNCTION public.fn_platform_set_trial(
  p_shop_id UUID,
  p_days    INT DEFAULT 90
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.fn_is_platform_admin() THEN
    RAISE EXCEPTION 'Solo el administrador de la plataforma' USING ERRCODE = '42501';
  END IF;
  IF p_days IS NULL OR p_days < 0 OR p_days > 365 THEN
    RAISE EXCEPTION 'La prueba debe durar entre 1 y 365 días' USING ERRCODE = '22023';
  END IF;

  UPDATE public.shops
     SET trial_ends_at = CASE
           WHEN p_days = 0 THEN NULL
           ELSE now() + make_interval(days => p_days)
         END
   WHERE id = p_shop_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local inexistente' USING ERRCODE = '22023';
  END IF;

  RETURN public.fn_shop_access(p_shop_id);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_platform_me() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_platform_shops() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_platform_set_suspension(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_platform_set_trial(UUID, INT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_is_platform_admin() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.fn_platform_me() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_platform_shops() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_platform_set_suspension(UUID, BOOLEAN, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_platform_set_trial(UUID, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_is_platform_admin() TO authenticated;

-- ============================================================
-- 5. BLOQUEO DE DATOS DEL LOCAL SUSPENDIDO O VENCIDO (RLS restrictiva)
-- Se suma con AND a las politicas existentes. `shops` queda legible para
-- que el dueño pueda ver el motivo; el resto del local no.
-- ============================================================
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'staff', 'catalog_items', 'clients', 'appointments', 'cash_movements', 'staff_invites'
  ]
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', 'shop_access_' || t, t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR ALL TO authenticated '
      'USING (public.fn_shop_usable(shop_id)) '
      'WITH CHECK (public.fn_shop_usable(shop_id))',
      'shop_access_' || t, t
    );
  END LOOP;
END $$;

-- ============================================================
-- 6. RESERVAS: LINK PUBLICO Y AGENDA
-- ============================================================

-- 6.1 Ocultar el local en el link publico si esta bloqueado.
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
    AND public.fn_shop_usable(s.id);
$$;

-- 6.2 Sin horarios si la licencia esta bloqueada.
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

-- 6.3 Ningun camino (publico o interno) inserta turnos en un local bloqueado.
CREATE OR REPLACE FUNCTION public.fn_appointments_require_shop_access()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.fn_shop_usable(NEW.shop_id) THEN
    RAISE EXCEPTION 'El local no está disponible para reservas' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appointments_shop_access ON public.appointments;
CREATE TRIGGER trg_appointments_shop_access
  BEFORE INSERT ON public.appointments
  FOR EACH ROW EXECUTE FUNCTION public.fn_appointments_require_shop_access();

-- ============================================================
-- 7. EL PROFESIONAL VE EL ESTADO DE LICENCIA DEL LOCAL
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
    'shop_access', public.fn_shop_access(s.id)
  )
  FROM public.staff st
  JOIN public.shops s ON s.id = st.shop_id
  WHERE st.user_id = auth.uid()
  LIMIT 1;
$$;

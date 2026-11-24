-- ============================================================
-- ANSTUDIOS - Esquema de base de datos (Supabase / PostgreSQL 15+)
-- Extraido de docs/02_DATABASE.md (tarea T-000).
-- Ejecutar completo en el SQL Editor de Supabase sobre un proyecto NUEVO.
-- Si se aplica sobre una base existente, revisar la seccion 3.3.
-- Contenido: extensiones, tablas, constraints, indices, RLS,
-- RPCs publicas, calculo de comisiones y liquidacion.
-- ============================================================

-- ============================================================
-- 1. EXTENSIONES Y CONVENCIONES
-- ============================================================
-- Necesaria para la restricción de no-solapamiento (uuid WITH = en GiST)
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- Supabase ya trae pgcrypto; gen_random_uuid() es nativo en PG13+.

-- ============================================================
-- 2.1 Locales
-- ============================================================
CREATE TABLE public.shops (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  name               TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 80),
  slug               TEXT NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9-]{3,60}$'),
  phone              TEXT,
  address            TEXT,
  description        TEXT CHECK (description IS NULL OR char_length(description) <= 600),
  whatsapp           TEXT,
  phone_landline     TEXT,
  phone_mobile       TEXT,
  maps_url           TEXT CHECK (maps_url IS NULL OR char_length(maps_url) <= 500),
  photo_url          TEXT CHECK (photo_url IS NULL OR char_length(photo_url) <= 500),
  timezone           TEXT NOT NULL DEFAULT 'America/Argentina/Buenos_Aires',
  open_time          TIME NOT NULL DEFAULT '09:00',
  close_time         TIME NOT NULL DEFAULT '21:00',
  slot_duration_min  INT  NOT NULL DEFAULT 30 CHECK (slot_duration_min BETWEEN 10 AND 120),
  professionals_can_book BOOLEAN NOT NULL DEFAULT false,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT shops_hours_valid CHECK (close_time > open_time)
);

-- ============================================================
-- 2.2 Profesionales / empleados / socios
-- ============================================================
CREATE TABLE public.staff (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id                UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL, -- login del profesional (H-01)
  name                   TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 80),
  role                   TEXT NOT NULL DEFAULT 'Profesional',
  phone                  TEXT,
  commission_pct         NUMERIC(5,2) NOT NULL DEFAULT 50.00 CHECK (commission_pct BETWEEN 0 AND 100),
  product_commission_pct NUMERIC(5,2) NOT NULL DEFAULT 10.00 CHECK (product_commission_pct BETWEEN 0 AND 100),
  is_active              BOOLEAN NOT NULL DEFAULT true,
  color_hex              TEXT NOT NULL DEFAULT '#1E293B' CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  photo_url              TEXT CHECK (photo_url IS NULL OR char_length(photo_url) <= 500),
  bio                    TEXT CHECK (bio IS NULL OR char_length(bio) <= 240),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- 2.3 Servicios y productos
-- ============================================================
CREATE TABLE public.catalog_items (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id              UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  type                 TEXT NOT NULL DEFAULT 'service' CHECK (type IN ('service', 'product')),
  name                 TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 120),
  duration_min         INT NOT NULL DEFAULT 30 CHECK (duration_min = 0 OR duration_min BETWEEN 5 AND 480),
  price                NUMERIC(12,2) NOT NULL CHECK (price >= 0),
  default_supply_cost  NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (default_supply_cost >= 0),
  is_public            BOOLEAN NOT NULL DEFAULT true,
  is_active            BOOLEAN NOT NULL DEFAULT true,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Un producto no se agenda: su duración es 0 y no aparece en el link público.
  CONSTRAINT catalog_items_product_shape CHECK (
    (type = 'product' AND duration_min = 0)
    OR (type = 'service' AND duration_min > 0)
  )
);

-- ============================================================
-- 2.4 Clientes + ficha técnica
-- ============================================================
CREATE TABLE public.clients (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id         UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  full_name       TEXT NOT NULL CHECK (char_length(trim(full_name)) BETWEEN 2 AND 80),
  phone           TEXT NOT NULL CHECK (char_length(phone) BETWEEN 8 AND 20),
  technical_notes TEXT CHECK (technical_notes IS NULL OR char_length(technical_notes) <= 2000),
  last_visit_at   TIMESTAMPTZ,
  total_visits    INT NOT NULL DEFAULT 0 CHECK (total_visits >= 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT clients_shop_phone_unique UNIQUE (shop_id, phone)
);

-- ============================================================
-- 2.5 Agenda de turnos
-- ============================================================
CREATE TABLE public.appointments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id               UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  client_id             UUID REFERENCES public.clients(id) ON DELETE SET NULL,
  staff_id              UUID NOT NULL REFERENCES public.staff(id) ON DELETE RESTRICT,
  service_id            UUID REFERENCES public.catalog_items(id) ON DELETE SET NULL,
  client_name_snapshot  TEXT NOT NULL CHECK (char_length(trim(client_name_snapshot)) BETWEEN 2 AND 80),
  client_phone_snapshot TEXT NOT NULL CHECK (char_length(client_phone_snapshot) BETWEEN 8 AND 20),
  starts_at             TIMESTAMPTZ NOT NULL,
  ends_at               TIMESTAMPTZ NOT NULL,
  status                TEXT NOT NULL DEFAULT 'confirmed'
                        CHECK (status IN ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled', 'no_show')),
  source                TEXT NOT NULL DEFAULT 'admin'
                        CHECK (source IN ('admin', 'public_link', 'walk_in')),
  reminder_sent         BOOLEAN NOT NULL DEFAULT false,
  notes                 TEXT CHECK (notes IS NULL OR char_length(notes) <= 500),
  status_changed_by     UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  status_changed_at     TIMESTAMPTZ,
  public_token          UUID NOT NULL DEFAULT gen_random_uuid(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT appointments_time_valid CHECK (ends_at > starts_at),
  CONSTRAINT appointments_start_aligned CHECK (date_trunc('minute', starts_at) = starts_at)
);

-- ============================================================
-- 2.6 Caja, cobros, gastos y liquidación
-- ============================================================
CREATE TABLE public.cash_movements (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id                UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  appointment_id         UUID REFERENCES public.appointments(id) ON DELETE SET NULL,
  staff_id               UUID REFERENCES public.staff(id) ON DELETE SET NULL,
  item_id                UUID REFERENCES public.catalog_items(id) ON DELETE SET NULL, -- servicio/producto vendido (H-06)

  movement_type          TEXT NOT NULL
                         CHECK (movement_type IN ('income', 'expense', 'staff_advance', 'commission_payout')),

  description            TEXT NOT NULL CHECK (char_length(trim(description)) BETWEEN 2 AND 200),
  payment_method         TEXT NOT NULL DEFAULT 'cash'
                         CHECK (payment_method IN ('cash', 'transfer', 'card', 'qr')),

  -- Desglose financiero (H-06: derivado y validado por trigger)
  gross_amount           NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (gross_amount >= 0),
  discount_amount        NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (discount_amount >= 0),
  supply_deduction       NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (supply_deduction >= 0),
  net_base_amount        NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (net_base_amount >= 0),

  commission_pct_applied NUMERIC(5,2) CHECK (commission_pct_applied BETWEEN 0 AND 100),
  staff_commission_amount NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (staff_commission_amount >= 0),
  shop_net_amount        NUMERIC(12,2) NOT NULL DEFAULT 0.00,

  is_settled             BOOLEAN NOT NULL DEFAULT false,
  movement_date          TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Coherencia por tipo (el trigger completa lo derivado)
  CONSTRAINT cash_income_needs_staff CHECK (movement_type <> 'income' OR staff_id IS NOT NULL),
  CONSTRAINT cash_advance_needs_staff CHECK (movement_type <> 'staff_advance' OR staff_id IS NOT NULL),
  CONSTRAINT cash_payout_needs_staff  CHECK (movement_type <> 'commission_payout' OR staff_id IS NOT NULL),
  CONSTRAINT cash_expense_no_commission CHECK (
    movement_type NOT IN ('expense', 'staff_advance', 'commission_payout')
    OR (discount_amount = 0 AND supply_deduction = 0 AND staff_commission_amount = 0)
  )
);

-- ============================================================
-- 3.1 No-solapamiento de turnos (H-05)
-- ============================================================
-- Requiere btree_gist. Garantiza que un profesional no tenga dos turnos activos superpuestos,
-- incluso si dos requests llegan al mismo milisegundo.
ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_no_overlap
  EXCLUDE USING gist (
    staff_id WITH =,
    tstzrange(starts_at, ends_at, '[)') WITH &&
  )
  WHERE (status IN ('pending', 'confirmed', 'in_progress'));

-- ============================================================
-- 3.3 Notas sobre migración incremental
-- ============================================================
ALTER TABLE public.shops  ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'America/Argentina/Buenos_Aires';
ALTER TABLE public.staff  ADD COLUMN IF NOT EXISTS user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_movements ADD COLUMN IF NOT EXISTS item_id UUID REFERENCES public.catalog_items(id) ON DELETE SET NULL;
-- y alinear defaults/checks de la sección 2 antes de aplicar índices y RLS.

-- ============================================================
-- 4. ÍNDICES
-- ============================================================
-- Locales
CREATE INDEX idx_shops_owner ON public.shops (owner_id);
-- slug ya tiene índice por UNIQUE.

-- Equipo
CREATE INDEX idx_staff_shop_active ON public.staff (shop_id) WHERE is_active;
CREATE INDEX idx_staff_user        ON public.staff (user_id) WHERE user_id IS NOT NULL;

-- Catálogo
CREATE INDEX idx_catalog_shop_type_active
  ON public.catalog_items (shop_id, type)
  WHERE is_active;
CREATE INDEX idx_catalog_shop_public
  ON public.catalog_items (shop_id)
  WHERE is_active AND is_public AND type = 'service';

-- Clientes (búsqueda por teléfono ya la cubre clients_shop_phone_unique)
CREATE INDEX idx_clients_shop_last_visit
  ON public.clients (shop_id, last_visit_at DESC NULLS LAST);

-- Agenda: vista diaria, agenda por profesional, historial por cliente
CREATE INDEX idx_appointments_shop_start
  ON public.appointments (shop_id, starts_at);
CREATE INDEX idx_appointments_staff_start_active
  ON public.appointments (staff_id, starts_at)
  WHERE status IN ('pending', 'confirmed', 'in_progress');
CREATE INDEX idx_appointments_shop_status_start
  ON public.appointments (shop_id, status, starts_at);
CREATE UNIQUE INDEX appointments_public_token_key
  ON public.appointments(public_token);
CREATE INDEX idx_appointments_client
  ON public.appointments (client_id)
  WHERE client_id IS NOT NULL;

-- Caja: listado por fecha, comisiones pendientes por profesional, detalle de turno
CREATE INDEX idx_cash_shop_date
  ON public.cash_movements (shop_id, movement_date DESC);
CREATE INDEX idx_cash_staff_pending
  ON public.cash_movements (staff_id, movement_date)
  WHERE is_settled = false AND movement_type IN ('income', 'staff_advance');
CREATE INDEX idx_cash_shop_type_date
  ON public.cash_movements (shop_id, movement_type, movement_date DESC);
CREATE INDEX idx_cash_appointment
  ON public.cash_movements (appointment_id)
  WHERE appointment_id IS NOT NULL;
CREATE INDEX idx_cash_item
  ON public.cash_movements (item_id)
  WHERE item_id IS NOT NULL;

-- ============================================================
-- 5. FUNCIONES DE AYUDA PARA RLS
-- ============================================================
-- Dueño del local
CREATE OR REPLACE FUNCTION public.is_shop_owner(p_shop_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.shops s
     WHERE s.id = p_shop_id AND s.owner_id = auth.uid()
  );
$$;

-- Ficha de profesional vinculada al usuario logueado dentro del local
CREATE OR REPLACE FUNCTION public.current_staff_id(p_shop_id UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT st.id
    FROM public.staff st
   WHERE st.shop_id = p_shop_id
     AND st.user_id = auth.uid()
     AND st.is_active
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_shop_staff(p_shop_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.current_staff_id(p_shop_id) IS NOT NULL;
$$;

-- ============================================================
-- 6. RLS — AISLAMIENTO POR shop_id
-- ============================================================
ALTER TABLE public.shops          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 6.1 Dueño / administrador
-- ============================================================
CREATE POLICY shops_owner_all ON public.shops
  FOR ALL TO authenticated
  USING (owner_id = auth.uid())
  WITH CHECK (owner_id = auth.uid());

CREATE POLICY staff_owner_all ON public.staff
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

CREATE POLICY catalog_owner_all ON public.catalog_items
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

CREATE POLICY clients_owner_all ON public.clients
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

CREATE POLICY appointments_owner_all ON public.appointments
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

CREATE POLICY cash_owner_all ON public.cash_movements
  FOR ALL TO authenticated
  USING (public.is_shop_owner(shop_id))
  WITH CHECK (public.is_shop_owner(shop_id));

-- ============================================================
-- 6.2 Profesional
-- ============================================================
-- Su propia ficha y el roster del local (nombre/color para pintar la agenda)
CREATE POLICY staff_self_read ON public.staff
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY staff_roster_read ON public.staff
  FOR SELECT TO authenticated
  USING (public.is_shop_staff(shop_id));

-- Catálogo visible del local
CREATE POLICY catalog_staff_read ON public.catalog_items
  FOR SELECT TO authenticated
  USING (public.is_shop_staff(shop_id) AND is_active);

-- Clientes solo si tuvo/tendrá un turno con ellos (ficha técnica incluida)
CREATE POLICY clients_staff_read ON public.clients
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1
        FROM public.appointments a
        JOIN public.staff st ON st.id = a.staff_id
       WHERE a.client_id = clients.id
         AND st.user_id = auth.uid()
    )
  );

-- Solo sus propios turnos
CREATE POLICY appointments_staff_read ON public.appointments
  FOR SELECT TO authenticated
  USING (
    staff_id IN (
      SELECT st.id FROM public.staff st WHERE st.user_id = auth.uid()
    )
  );

-- Solo sus comisiones, adelantos y liquidaciones; nunca gastos del local
CREATE POLICY cash_staff_read ON public.cash_movements
  FOR SELECT TO authenticated
  USING (
    staff_id IN (
      SELECT st.id FROM public.staff st WHERE st.user_id = auth.uid()
    )
    AND movement_type IN ('income', 'staff_advance', 'commission_payout')
  );

-- ============================================================
-- 6.3 Anónimo (anon)
-- ============================================================
-- Sin políticas para anon: RLS deniega todo por defecto.
-- Además se revocan grants para no depender de los privilegios por defecto de Supabase.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;

-- ============================================================
-- 7.2 Datos públicos del local + catálogo
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
               jsonb_build_object('id', st.id, 'name', st.name, 'color_hex', st.color_hex)
               ORDER BY st.name)
        FROM public.staff st
       WHERE st.shop_id = s.id AND st.is_active
    ), '[]'::jsonb)
  )
  FROM public.shops s
  WHERE s.slug = lower(trim(p_slug));
$$;

-- ============================================================
-- 7.3 Disponibilidad real (solo horarios libres)
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
BEGIN
  SELECT * INTO v_shop FROM public.shops WHERE slug = lower(trim(p_slug));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023';
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
-- 7.4 Crear la reserva (escritura controlada)
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

  -- Saneamiento mínimo de datos libres
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

  -- Freno anti-abuso: máximo 3 reservas públicas pendientes por teléfono y local
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

  -- Reutiliza el cliente existente sin permitir que el público lo renombre
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
    RETURNING id INTO v_appt_id;
  EXCEPTION WHEN exclusion_violation THEN
    RAISE EXCEPTION 'Ese horario acaba de ocuparse, elegí otro'
      USING ERRCODE = '23P01';
  END;

  RETURN jsonb_build_object(
    'appointment_id', v_appt_id,
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
-- 7.5 Grants de las RPCs públicas
-- ============================================================
GRANT EXECUTE ON FUNCTION public.fn_public_shop(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_availability(TEXT, UUID, DATE, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ============================================================
-- 8.1 Trigger de cálculo y validación cruzada
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_cash_movement_compute()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_staff_shop UUID;
  v_item_shop  UUID;
  v_item_type  TEXT;
BEGIN
  NEW.gross_amount            := COALESCE(NEW.gross_amount, 0);
  NEW.discount_amount         := COALESCE(NEW.discount_amount, 0);
  NEW.supply_deduction        := COALESCE(NEW.supply_deduction, 0);
  NEW.net_base_amount         := COALESCE(NEW.net_base_amount, 0);
  NEW.staff_commission_amount := COALESCE(NEW.staff_commission_amount, 0);
  NEW.shop_net_amount         := COALESCE(NEW.shop_net_amount, 0);
  NEW.movement_date           := COALESCE(NEW.movement_date, now());

  -- Integridad multi-local
  IF NEW.appointment_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.appointments a
     WHERE a.id = NEW.appointment_id AND a.shop_id = NEW.shop_id
  ) THEN
    RAISE EXCEPTION 'El turno no pertenece al local' USING ERRCODE = '23514';
  END IF;

  IF NEW.staff_id IS NOT NULL THEN
    SELECT st.shop_id INTO v_staff_shop FROM public.staff st WHERE st.id = NEW.staff_id;
    IF v_staff_shop IS DISTINCT FROM NEW.shop_id THEN
      RAISE EXCEPTION 'El profesional no pertenece al local' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.item_id IS NOT NULL THEN
    SELECT c.shop_id, c.type INTO v_item_shop, v_item_type
      FROM public.catalog_items c WHERE c.id = NEW.item_id;
    IF v_item_shop IS DISTINCT FROM NEW.shop_id THEN
      RAISE EXCEPTION 'El ítem no pertenece al local' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.movement_type = 'income' THEN
    IF NEW.discount_amount + NEW.supply_deduction > NEW.gross_amount THEN
      RAISE EXCEPTION 'Descuento + insumos supera el monto bruto' USING ERRCODE = '23514';
    END IF;

    -- Base comisionable: lo que queda después de descuento al cliente e insumos
    NEW.net_base_amount := NEW.gross_amount - NEW.discount_amount - NEW.supply_deduction;

    IF NEW.staff_id IS NULL THEN
      NEW.commission_pct_applied := 0;
    ELSIF NEW.commission_pct_applied IS NULL THEN
      -- Servicio -> commission_pct; Producto -> product_commission_pct
      SELECT CASE WHEN v_item_type = 'product'
                  THEN st.product_commission_pct
                  ELSE st.commission_pct
             END
        INTO NEW.commission_pct_applied
        FROM public.staff st
       WHERE st.id = NEW.staff_id;
    END IF;

    NEW.commission_pct_applied := COALESCE(NEW.commission_pct_applied, 0);
    NEW.staff_commission_amount := ROUND(
      NEW.net_base_amount * NEW.commission_pct_applied / 100.0, 2
    );
    NEW.shop_net_amount := NEW.net_base_amount - NEW.staff_commission_amount;

  ELSIF NEW.movement_type = 'expense' THEN
    -- Gasto del local: afecta la caja como negativo, sin comisión
    NEW.discount_amount         := 0;
    NEW.supply_deduction        := 0;
    NEW.net_base_amount         := 0;
    NEW.commission_pct_applied  := 0;
    NEW.staff_commission_amount := 0;
    NEW.shop_net_amount         := -NEW.gross_amount;
    NEW.is_settled              := false;

  ELSIF NEW.movement_type = 'staff_advance' THEN
    -- Adelanto: sale de caja, se descuenta de la liquidación (is_settled = descontado)
    NEW.discount_amount         := 0;
    NEW.supply_deduction        := 0;
    NEW.net_base_amount         := 0;
    NEW.commission_pct_applied  := 0;
    NEW.staff_commission_amount := 0;
    NEW.shop_net_amount         := 0;

  ELSE -- commission_payout
    NEW.discount_amount         := 0;
    NEW.supply_deduction        := 0;
    NEW.net_base_amount         := 0;
    NEW.commission_pct_applied  := 0;
    NEW.staff_commission_amount := 0;
    NEW.shop_net_amount         := 0;
    NEW.is_settled              := true;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cash_movement_compute
  BEFORE INSERT OR UPDATE ON public.cash_movements
  FOR EACH ROW EXECUTE FUNCTION public.fn_cash_movement_compute();

-- ============================================================
-- 8.3 Vista de saldos pendientes por profesional
-- ============================================================
CREATE OR REPLACE VIEW public.v_staff_settlement_open
WITH (security_invoker = true)
AS
SELECT
  st.shop_id,
  st.id AS staff_id,
  st.name AS staff_name,
  COALESCE(SUM(cm.staff_commission_amount) FILTER (WHERE cm.movement_type = 'income'), 0) AS pending_commission,
  COALESCE(SUM(cm.gross_amount) FILTER (WHERE cm.movement_type = 'staff_advance'), 0) AS pending_advances,
  COUNT(cm.id) FILTER (WHERE cm.movement_type = 'income') AS pending_income_count,
  COALESCE(SUM(cm.staff_commission_amount) FILTER (WHERE cm.movement_type = 'income'), 0)
    - COALESCE(SUM(cm.gross_amount) FILTER (WHERE cm.movement_type = 'staff_advance'), 0) AS balance_due
FROM public.staff st
LEFT JOIN public.cash_movements cm
  ON cm.staff_id = st.id
 AND cm.is_settled = false
 AND cm.movement_type IN ('income', 'staff_advance')
GROUP BY st.shop_id, st.id, st.name;

-- La vista no entra en "ALL TABLES": grants explícitos
REVOKE ALL ON public.v_staff_settlement_open FROM anon;
GRANT SELECT ON public.v_staff_settlement_open TO authenticated;

-- ============================================================
-- 8.4 Preview de liquidación por período
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_staff_settlement_preview(
  p_shop_id      UUID,
  p_staff_id     UUID,
  p_period_start TIMESTAMPTZ,
  p_period_end   TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_gross NUMERIC := 0;
  v_discount NUMERIC := 0;
  v_supply NUMERIC := 0;
  v_base NUMERIC := 0;
  v_commission NUMERIC := 0;
  v_income_count INT := 0;
  v_advances NUMERIC := 0;
  v_advances_count INT := 0;
BEGIN
  IF NOT (public.is_shop_owner(p_shop_id) OR public.current_staff_id(p_shop_id) = p_staff_id) THEN
    RAISE EXCEPTION 'No autorizado para ver esta liquidación' USING ERRCODE = '42501';
  END IF;
  IF p_period_end <= p_period_start THEN
    RAISE EXCEPTION 'Rango de fechas inválido' USING ERRCODE = '22023';
  END IF;

  SELECT
    COALESCE(SUM(cm.gross_amount), 0),
    COALESCE(SUM(cm.discount_amount), 0),
    COALESCE(SUM(cm.supply_deduction), 0),
    COALESCE(SUM(cm.net_base_amount), 0),
    COALESCE(SUM(cm.staff_commission_amount), 0),
    COUNT(cm.id)
  INTO v_gross, v_discount, v_supply, v_base, v_commission, v_income_count
  FROM public.cash_movements cm
  WHERE cm.shop_id = p_shop_id
    AND cm.staff_id = p_staff_id
    AND cm.movement_type = 'income'
    AND cm.is_settled = false
    AND cm.movement_date >= p_period_start
    AND cm.movement_date <  p_period_end;

  SELECT COALESCE(SUM(cm.gross_amount), 0), COUNT(cm.id)
  INTO v_advances, v_advances_count
  FROM public.cash_movements cm
  WHERE cm.shop_id = p_shop_id
    AND cm.staff_id = p_staff_id
    AND cm.movement_type = 'staff_advance'
    AND cm.is_settled = false
    AND cm.movement_date < p_period_end;

  RETURN jsonb_build_object(
    'shop_id', p_shop_id,
    'staff_id', p_staff_id,
    'period_start', p_period_start,
    'period_end', p_period_end,
    'income_count', v_income_count,
    'gross_total', v_gross,
    'discount_total', v_discount,
    'supply_total', v_supply,
    'net_base_total', v_base,
    'commission_total', v_commission,
    'advances_count', v_advances_count,
    'advances_total', v_advances,
    'payout_due', v_commission - v_advances
  );
END;
$$;

-- ============================================================
-- 8.5 Cierre atómico de liquidación
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_settle_staff_commissions(
  p_shop_id        UUID,
  p_staff_id       UUID,
  p_period_start   TIMESTAMPTZ,
  p_period_end     TIMESTAMPTZ,
  p_payment_method TEXT DEFAULT 'cash',
  p_notes          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_preview   JSONB;
  v_payout    NUMERIC;
  v_advances  NUMERIC;
  v_payout_id UUID;
BEGIN
  IF NOT public.is_shop_owner(p_shop_id) THEN
    RAISE EXCEPTION 'Solo el dueño puede cerrar liquidaciones' USING ERRCODE = '42501';
  END IF;
  IF p_payment_method NOT IN ('cash', 'transfer', 'card', 'qr') THEN
    RAISE EXCEPTION 'Medio de pago inválido' USING ERRCODE = '22023';
  END IF;
  IF p_period_end <= p_period_start THEN
    RAISE EXCEPTION 'Rango de fechas inválido' USING ERRCODE = '22023';
  END IF;

  -- Serializa por profesional: dos cierres concurrentes no pueden pagar dos veces
  PERFORM 1
    FROM public.staff st
   WHERE st.id = p_staff_id AND st.shop_id = p_shop_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profesional inexistente en este local' USING ERRCODE = '22023';
  END IF;

  -- Bloquea comisiones y adelantos alcanzados por el cierre
  PERFORM 1
    FROM public.cash_movements cm
   WHERE cm.shop_id = p_shop_id
     AND cm.staff_id = p_staff_id
     AND cm.is_settled = false
     AND cm.movement_type IN ('income', 'staff_advance')
     AND cm.movement_date < p_period_end
   FOR UPDATE;

  v_preview  := public.fn_staff_settlement_preview(p_shop_id, p_staff_id, p_period_start, p_period_end);
  v_payout   := (v_preview ->> 'payout_due')::NUMERIC;
  v_advances := (v_preview ->> 'advances_total')::NUMERIC;

  IF (v_preview ->> 'income_count')::INT = 0
     AND (v_preview ->> 'advances_count')::INT = 0 THEN
    RETURN v_preview || jsonb_build_object('settled', false, 'reason', 'sin_movimientos');
  END IF;

  -- Si los adelantos superan la comisión, no se cierra: el saldo queda a favor del local
  IF v_payout < 0 THEN
    RETURN v_preview || jsonb_build_object('settled', false, 'reason', 'saldo_a_favor_del_local');
  END IF;

  UPDATE public.cash_movements
     SET is_settled = true
   WHERE shop_id = p_shop_id
     AND staff_id = p_staff_id
     AND movement_type = 'income'
     AND is_settled = false
     AND movement_date >= p_period_start
     AND movement_date <  p_period_end;

  UPDATE public.cash_movements
     SET is_settled = true
   WHERE shop_id = p_shop_id
     AND staff_id = p_staff_id
     AND movement_type = 'staff_advance'
     AND is_settled = false
     AND movement_date < p_period_end;

  IF v_payout > 0 THEN
    INSERT INTO public.cash_movements (
      shop_id, staff_id, movement_type, description, payment_method,
      gross_amount, discount_amount, supply_deduction, net_base_amount,
      staff_commission_amount, shop_net_amount, is_settled, movement_date
    ) VALUES (
      p_shop_id, p_staff_id, 'commission_payout',
      COALESCE(
        NULLIF(btrim(COALESCE(p_notes, '')), ''),
        'Liquidación de comisiones ' || to_char(p_period_start, 'DD/MM/YYYY')
          || ' al ' || to_char(p_period_end - interval '1 second', 'DD/MM/YYYY')
      ),
      p_payment_method,
      v_payout, 0, 0, 0, 0, 0, true, now()
    )
    RETURNING id INTO v_payout_id;
  END IF;

  RETURN v_preview || jsonb_build_object(
    'settled', true,
    'advances_deducted', v_advances,
    'payout_amount', v_payout,
    'payout_id', v_payout_id
  );
END;
$$;

-- ============================================================
-- 8.6 Grants de las funciones sensibles
-- ============================================================
REVOKE ALL ON FUNCTION public.fn_staff_settlement_preview(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_settle_staff_commissions(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_staff_settlement_preview(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_settle_staff_commissions(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT) TO authenticated;

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


-- ============================================================
-- Migración T-020: feed ICS por profesional (calendar_token + RPCs)
-- ============================================================
-- ============================================================
-- T-020: Feed ICS de solo lectura por profesional
-- ============================================================
-- Cada profesional tiene un token aleatorio (capability URL) que la
-- Edge Function `calendar-feed` usa para devolver sus turnos como
-- text/calendar. El token se puede regenerar para revocar el acceso.
-- No se expone por `select *`: el frontend pide el token por RPC.

ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS calendar_token UUID;

UPDATE public.staff
SET calendar_token = gen_random_uuid()
WHERE calendar_token IS NULL;

ALTER TABLE public.staff
  ALTER COLUMN calendar_token SET DEFAULT gen_random_uuid(),
  ALTER COLUMN calendar_token SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_staff_calendar_token
  ON public.staff (calendar_token);

-- Devuelve el token del profesional pedido (o del propio profesional
-- logueado si p_staff_id es NULL). Solo dueño del local o el propio
-- profesional pueden leerlo.
CREATE OR REPLACE FUNCTION public.fn_calendar_token(p_staff_id UUID DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
BEGIN
  SELECT s.* INTO v_staff
  FROM public.staff s
  WHERE s.id = COALESCE(
    p_staff_id,
    (SELECT own.id FROM public.staff own WHERE own.user_id = auth.uid())
  );

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Profesional no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    public.is_shop_owner(v_staff.shop_id)
    OR v_staff.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'No tenés permiso para ver ese calendario' USING ERRCODE = '42501';
  END IF;

  RETURN v_staff.calendar_token;
END;
$$;

-- Regenera el token: invalida el link anterior de inmediato.
CREATE OR REPLACE FUNCTION public.fn_rotate_calendar_token(p_staff_id UUID DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_staff public.staff;
  v_token UUID := gen_random_uuid();
BEGIN
  SELECT s.* INTO v_staff
  FROM public.staff s
  WHERE s.id = COALESCE(
    p_staff_id,
    (SELECT own.id FROM public.staff own WHERE own.user_id = auth.uid())
  );

  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'Profesional no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF NOT (
    public.is_shop_owner(v_staff.shop_id)
    OR v_staff.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'No tenés permiso para cambiar ese calendario' USING ERRCODE = '42501';
  END IF;

  UPDATE public.staff SET calendar_token = v_token WHERE id = v_staff.id;
  RETURN v_token;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_calendar_token(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_rotate_calendar_token(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_calendar_token(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_rotate_calendar_token(UUID) TO authenticated;

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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
  ADD COLUMN IF NOT EXISTS can_book_appointments BOOLEAN NOT NULL DEFAULT false;

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
    'shop_professional_booking_mode', v_shop.professional_booking_mode,
    'shop_public_booking_enabled', v_shop.public_booking_enabled,
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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
  ADD COLUMN IF NOT EXISTS can_book_appointments BOOLEAN NOT NULL DEFAULT false;

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
    'shop_professional_booking_mode', v_shop.professional_booking_mode,
    'shop_public_booking_enabled', v_shop.public_booking_enabled,
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
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS working_days   INTEGER[],
  ADD COLUMN IF NOT EXISTS work_start_time TIME,
  ADD COLUMN IF NOT EXISTS work_end_time   TIME;

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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
  ADD COLUMN IF NOT EXISTS can_book_appointments BOOLEAN NOT NULL DEFAULT false;

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
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS working_days   INTEGER[],
  ADD COLUMN IF NOT EXISTS work_start_time TIME,
  ADD COLUMN IF NOT EXISTS work_end_time   TIME;

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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
  ADD COLUMN IF NOT EXISTS can_book_appointments BOOLEAN NOT NULL DEFAULT false;

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
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.staff
  ADD COLUMN IF NOT EXISTS working_days   INTEGER[],
  ADD COLUMN IF NOT EXISTS work_start_time TIME,
  ADD COLUMN IF NOT EXISTS work_end_time   TIME;

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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

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
  ADD COLUMN IF NOT EXISTS public_booking_enabled BOOLEAN NOT NULL DEFAULT true;

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
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS professionals_can_manage_appointments BOOLEAN NOT NULL DEFAULT false;

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
-- ============================================================
-- ANSTUDIOS - Buscar turno existente por teléfono/nombre (link público)
-- Migracion 2026-11-26
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_public_find_appointments(
  p_slug   TEXT,
  p_phone  TEXT DEFAULT NULL,
  p_name   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_shop   public.shops;
  v_phone  TEXT;
  v_name   TEXT;
  v_rows   JSONB;
BEGIN
  SELECT * INTO v_shop FROM public.shops WHERE slug = lower(trim(p_slug));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Local no encontrado' USING ERRCODE = '22023';
  END IF;

  IF v_shop.is_suspended THEN
    RAISE EXCEPTION 'Este local no está disponible en este momento.' USING ERRCODE = '22023';
  END IF;
  IF v_shop.trial_ends_at IS NOT NULL AND v_shop.trial_ends_at < now() THEN
    RAISE EXCEPTION 'Este local no está disponible en este momento.' USING ERRCODE = '22023';
  END IF;
  IF NOT COALESCE(v_shop.public_booking_enabled, true) THEN
    RAISE EXCEPTION 'Las reservas online están desactivadas.' USING ERRCODE = '22023';
  END IF;

  v_phone := regexp_replace(COALESCE(p_phone, ''), '[^0-9]', '', 'g');
  v_name  := btrim(COALESCE(p_name, ''));

  IF char_length(v_phone) < 8 AND char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'Ingresá un teléfono o nombre válido.' USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'appointment_id', a.id,
    'public_token', a.public_token,
    'starts_at', a.starts_at,
    'ends_at', a.ends_at,
    'status', a.status,
    'service_name', c.name,
    'staff_name', st.name,
    'client_name', a.client_name_snapshot
  ) ORDER BY a.starts_at), '[]'::jsonb)
  INTO v_rows
  FROM public.appointments a
  LEFT JOIN public.catalog_items c ON c.id = a.service_id
  LEFT JOIN public.staff st ON st.id = a.staff_id
  WHERE a.shop_id = v_shop.id
    AND a.public_token IS NOT NULL
    AND a.starts_at >= now() - interval '1 day'
    AND (
      (char_length(v_phone) >= 8 AND regexp_replace(a.client_phone_snapshot, '[^0-9]', '', 'g') = v_phone)
      OR (char_length(v_name) >= 2 AND a.client_name_snapshot ILIKE '%' || v_name || '%')
    );

  RETURN v_rows;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_public_find_appointments(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_public_find_appointments(TEXT, TEXT, TEXT) TO anon, authenticated;

# BASE DE DATOS — ANSTUDIOS (SUPABASE / POSTGRESQL 15+)

Versión auditada del esquema. Este documento es la **fuente de verdad** para Supabase: puede ejecutarse de arriba a abajo en el SQL Editor (o como migración) y deja la base lista para las tareas T-001 a T-010.

Alcance de la auditoría T-000:
1. Índices para los caminos calientes (agenda, caja, link público).
2. RLS seguro y aislado por `shop_id` (dueño vs. profesional vs. anónimo).
3. Reserva pública sin exponer datos de otros clientes (RPCs `SECURITY DEFINER`, cero acceso directo a tablas para `anon`).
4. Cálculo y liquidación de comisiones con descuentos e insumos, consistente a nivel de base (trigger + preview + cierre atómico).

> **Regla de oro:** el frontend nunca calcula dinero ni confía en `shop_id` enviado por el cliente. Los montos derivados y la pertenencia al local se validan en la base.

---

## 0. HALLAZGOS DE LA AUDITORÍA Y SU CORRECCIÓN

| ID | Hallazgo en la versión anterior | Riesgo | Corrección |
|----|--------------------------------|--------|------------|
| H-01 | `staff` no tenía vínculo con `auth.users` | Imposible hacer RLS "el profesional ve solo lo suyo"; todo quedaba a nivel dueño | Nueva columna `staff.user_id UUID UNIQUE REFERENCES auth.users(id)` |
| H-02 | Sin índices salvo PK/UNIQUE | Escaneos secuenciales en agenda y caja al crecer el local | Sección 4 |
| H-03 | Sin RLS + grants por defecto de Supabase a `anon` | Un `anon` podía leer `clients`, `appointments` y `cash_movements` | Sección 6 + `REVOKE` explícito a `anon` |
| H-04 | La reserva pública obligaba a insertar directo en `clients`/`appointments` | Exposición de datos de terceros y escritura arbitraria de `shop_id`, `status`, `price` | RPCs `SECURITY DEFINER` con contrato cerrado (sección 7) |
| H-05 | Nada impedía el solapamiento de turnos ante doble clic / concurrencia | Dos clientes en el mismo horario con el mismo profesional | `EXCLUDE USING gist` sobre rango de tiempo por profesional |
| H-06 | `net_base_amount` / `staff_commission_amount` / `shop_net_amount` eran libres | Caja inconsistente y comisiones de producto calculadas con el % de servicio | Trigger `fn_cash_movement_compute` + `cash_movements.item_id` |
| H-07 | `is_settled` significaba cosas distintas según el tipo de movimiento | Adelantos descontados dos veces o comisiones pagadas sin marcar | Semántica explícita por tipo (sección 9) |
| H-08 | Horarios públicos calculados con UTC-3 fijo en el frontend | Desfase al cambiar de zona o al renderizar en otro país | `shops.timezone` + cálculo en SQL (sección 7) |
| H-09 | Faltaban checks de montos negativos, `ends_at > starts_at`, teléfono/nombre | Datos basura y montos imposibles | Sección 3 |

Decisiones de diseño tomadas:
- Se mantiene **una sola base multi-local** aislada por `shop_id` (sirve también para instancia dedicada: un único `shop`).
- La disponibilidad pública se expone **solo como horarios libres**, nunca como turnos ocupados con nombre/teléfono.
- El cierre de liquidación es **una transacción**: o se marcan comisiones + adelantos y se registra el pago, o no se toca nada.

---

## 1. EXTENSIONES Y CONVENCIONES

```sql
-- Necesaria para la restricción de no-solapamiento (uuid WITH = en GiST)
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- Supabase ya trae pgcrypto; gen_random_uuid() es nativo en PG13+.
```

Convenciones:
- Todos los importes son `NUMERIC(12,2)` en **ARS**, sin floats.
- Fechas de negocio en `TIMESTAMPTZ`; la zona del local vive en `shops.timezone`.
- Todo acceso a datos de negocio filtra por `shop_id` y pasa por RLS.
- Funciones `SECURITY DEFINER` siempre con `SET search_path = ''` y nombres totalmente calificados (`public.*`, `auth.uid()`), para evitar secuestro de `search_path`.
- Los slugs se guardan y comparan en minúsculas.

---

## 2. ESQUEMA COMPLETO (DDL)

### 2.1 Locales

```sql
CREATE TABLE public.shops (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  name               TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 80),
  slug               TEXT NOT NULL UNIQUE CHECK (slug = lower(slug) AND slug ~ '^[a-z0-9-]{3,60}$'),
  phone              TEXT,
  address            TEXT,
  timezone           TEXT NOT NULL DEFAULT 'America/Argentina/Buenos_Aires',
  open_time          TIME NOT NULL DEFAULT '09:00',
  close_time         TIME NOT NULL DEFAULT '21:00',
  slot_duration_min  INT  NOT NULL DEFAULT 30 CHECK (slot_duration_min BETWEEN 10 AND 120),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT shops_hours_valid CHECK (close_time > open_time)
);
```

- `timezone` se agrega para calcular disponibilidad pública en SQL (H-08). No hardcodear UTC-3.
- `close_time > open_time` impide locales con horario invertido en esta versión (sin turnos noche).

### 2.2 Profesionales / empleados / socios

```sql
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
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- `user_id` es el puente con `auth.users` que usa RLS. Puede ser `NULL` (profesional sin acceso a la app).
- Un mismo usuario no puede estar vinculado a dos fichas de profesional (`UNIQUE`).

### 2.3 Servicios y productos

```sql
CREATE TABLE public.catalog_items (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id              UUID NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  type                 TEXT NOT NULL DEFAULT 'service' CHECK (type IN ('service', 'product')),
  name                 TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 2 AND 120),
  duration_min         INT NOT NULL DEFAULT 30 CHECK (duration_min BETWEEN 5 AND 480),
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
```

> `default_supply_cost` es el costo sugerido (ej. tintura). El costo real usado en caja es `cash_movements.supply_deduction`, que el dueño puede ajustar por operación.

### 2.4 Clientes + ficha técnica

```sql
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
```

- El teléfono es la clave natural del cliente dentro del local (`UNIQUE (shop_id, phone)`), que además crea el índice usado por la reserva pública.

### 2.5 Agenda de turnos

```sql
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
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT appointments_time_valid CHECK (ends_at > starts_at),
  CONSTRAINT appointments_start_aligned CHECK (date_trunc('minute', starts_at) = starts_at)
);
```

> `staff_id` pasa de `SET NULL` a `RESTRICT`: un turno no puede quedar sin profesional (rompía la agenda y la comisión). El borrado de un profesional con historial debe ser lógico (`is_active = false`).

### 2.6 Caja, cobros, gastos y liquidación

```sql
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
```

> `commission_pct_applied NULL` = "usá el porcentaje configurado en `staff` para el tipo de ítem". Un `0` explícito es respetado (cortesía / bonificación total).

---

## 3. INTEGRIDAD

### 3.1 No-solapamiento de turnos (H-05)

```sql
-- Requiere btree_gist. Garantiza que un profesional no tenga dos turnos activos superpuestos,
-- incluso si dos requests llegan al mismo milisegundo.
ALTER TABLE public.appointments
  ADD CONSTRAINT appointments_no_overlap
  EXCLUDE USING gist (
    staff_id WITH =,
    tstzrange(starts_at, ends_at, '[)') WITH &&
  )
  WHERE (status IN ('pending', 'confirmed', 'in_progress'));
```

- Cota `[)` evita falsos positivos entre turnos consecutivos (10:00–10:30 y 10:30–11:00).
- Turnos `cancelled` / `no_show` / `completed` quedan fuera de la restricción: liberan el horario.

### 3.2 Pertenencia al local a nivel de fila

La base no puede confiar en que la app envíe un `shop_id` coherente entre tablas hijas. Se valida con trigger (sección 8.1) para:
- `appointments.client_id` / `staff_id` / `service_id` pertenecientes al mismo `shop_id`.
- `cash_movements.appointment_id` / `staff_id` / `item_id` pertenecientes al mismo `shop_id`.

### 3.3 Notas sobre migración incremental

Si la base ya existe, las columnas nuevas son:

```sql
ALTER TABLE public.shops  ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'America/Argentina/Buenos_Aires';
ALTER TABLE public.staff  ADD COLUMN IF NOT EXISTS user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.cash_movements ADD COLUMN IF NOT EXISTS item_id UUID REFERENCES public.catalog_items(id) ON DELETE SET NULL;
-- y alinear defaults/checks de la sección 2 antes de aplicar índices y RLS.
```

---

## 4. ÍNDICES

```sql
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
```

Criterio: índices parciales para los estados vivos de agenda y para comisiones impagas; el resto son FKs y columnas de orden/filtro usadas por las pantallas de T-003 a T-008.

---

## 5. FUNCIONES DE AYUDA PARA RLS

`SECURITY DEFINER` evita recursión de políticas (una política de `staff` que consulte `staff` fallaría con "infinite recursion detected") y centraliza la regla de pertenencia.

```sql
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
```

---

## 6. RLS — AISLAMIENTO POR `shop_id`

Se habilita RLS en todas las tablas. `anon` **no tiene ninguna política**: su único camino son las RPCs de la sección 7.

```sql
ALTER TABLE public.shops          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointments   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cash_movements ENABLE ROW LEVEL SECURITY;
```

### 6.1 Dueño / administrador

```sql
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
```

### 6.2 Profesional

Lectura acotada. **No tiene políticas de escritura**: crear/editar turnos, cobros y clientes es del dueño. Los cambios de estado de su propia agenda quedan para una RPC dedicada cuando exista login de profesional; T-005 implementó la actualización de estados del dueño vía RLS.

```sql
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
```

### 6.3 Anónimo (`anon`)

```sql
-- Sin políticas para anon: RLS deniega todo por defecto.
-- Además se revocan grants para no depender de los privilegios por defecto de Supabase.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
```

> Si en el futuro se agregan tablas, repetir el `REVOKE` (los `ALTER DEFAULT PRIVILEGES` de Supabase no lo cubren automáticamente).

### 6.4 Matriz de acceso

| Tabla | `anon` | Profesional | Dueño |
|-------|--------|-------------|-------|
| `shops` | ❌ (solo vía RPC) | ❌ | ✅ fila propia (`owner_id`) |
| `staff` | ❌ | 👁 roster del local + ficha propia | ✅ CRUD |
| `catalog_items` | ❌ (solo vía RPC) | 👁 activos del local | ✅ CRUD |
| `clients` | ❌ | 👁 solo clientes con turno propio | ✅ CRUD |
| `appointments` | ❌ (solo vía RPC) | 👁 solo los propios | ✅ CRUD |
| `cash_movements` | ❌ | 👁 solo lo propio (sin gastos) | ✅ CRUD |
| `staff_invites` | ❌ | ❌ (solo vía RPC de reclamo) | ✅ CRUD |

---

## 7. RESERVA PÚBLICA SEGURA (`/r/:slug`)

### 7.1 Qué NO se expone

- Nunca se entrega a `anon` el listado de turnos ocupados, ni nombres, ni teléfonos, ni IDs de clientes.
- `fn_public_availability` devuelve **solo horarios libres** por profesional.
- `fn_public_create_booking` devuelve **solo** `appointment_id`, fechas, nombre del servicio, nombre del profesional y del local. No devuelve `client_id`, ni el teléfono normalizado, ni el estado de otros turnos.
- El `shop_id` y el `status` los fija la función, no el navegador.
- Si dos personas reservan el mismo horario, la restricción `appointments_no_overlap` decide y la RPC responde "horario acaba de ocuparse" (`23P01`). Nunca se crea un turno duplicado.

### 7.2 Datos públicos del local + catálogo

```sql
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
```

`shop.owner_id`, `created_at` y datos internos quedan fuera del payload.

### 7.3 Disponibilidad real (solo horarios libres)

```sql
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
```

Puntos clave:
- Grilla anclada a `open_time` del local y a `slot_duration_min`, con `timezone` del local.
- Solo se descartan horarios, no se informa *por qué* (no hay fuga de identidad).
- Antelación mínima de 30 minutos.
- Límite de 90 días a futuro.

### 7.4 Crear la reserva (escritura controlada)

```sql
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
```

Notas:
- La reserva nace `pending` y con `source = 'public_link'`; el dueño la confirma desde la agenda.
- El cliente existente conserva su nombre y ficha técnica: el formulario público no puede sobrescribir datos.
- La verificación de horario + la restricción de exclusión cubren la carrera entre disponibilidad y guardado.

### 7.5 Grants de las RPCs públicas

```sql
GRANT EXECUTE ON FUNCTION public.fn_public_shop(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_availability(TEXT, UUID, DATE, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_public_create_booking(TEXT, UUID, UUID, TIMESTAMPTZ, TEXT, TEXT, TEXT) TO anon, authenticated;
```

---

## 8. COMISIONES, DESCUENTOS E INSUMOS

### 8.1 Trigger de cálculo y validación cruzada

Se ejecuta `BEFORE INSERT OR UPDATE` y es la única fuente de verdad de `net_base_amount`, `staff_commission_amount`, `shop_net_amount` y `commission_pct_applied`.

```sql
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
```

### 8.2 Fórmulas (documentadas para la UI y las pruebas)

| Concepto | Fórmula | Ejemplo |
|----------|---------|---------|
| Base comisionable | `gross_amount - discount_amount - supply_deduction` | 20.000 − 2.000 − 1.500 = **16.500** |
| Comisión profesional | `round(net_base_amount × commission_pct_applied / 100, 2)` | 16.500 × 50% = **8.250** |
| Neto del local | `net_base_amount - staff_commission_amount` | 16.500 − 8.250 = **8.250** |
| A pagar en liquidación | `comisiones pendientes − adelantos pendientes` | 8.250 − 3.000 = **5.250** |

Reglas de negocio asociadas:
- El descuento al cliente **baja** la base comisionable (el profesional comisiona sobre lo realmente cobrado).
- El insumo se descuenta **antes** de comisionar y también baja el neto del local.
- Venta de producto: si `item_id` es `product`, se aplica `staff.product_commission_pct`; si es `service` o no hay ítem, `staff.commission_pct`.
- Gasto del local (`expense`) no lleva comisión y no entra en la liquidación.
- Todo redondeo es a 2 decimales con `ROUND` de `NUMERIC` (sin errores de float).

### 8.3 Vista de saldos pendientes por profesional

```sql
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
```

`security_invoker = true` (PG15+) hace que la vista respete la RLS del que consulta: el profesional ve su fila, el dueño ve todo el local.

```sql
-- La vista no entra en "ALL TABLES": grants explícitos
REVOKE ALL ON public.v_staff_settlement_open FROM anon;
GRANT SELECT ON public.v_staff_settlement_open TO authenticated;
```

### 8.4 Preview de liquidación por período

```sql
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
```

### 8.5 Cierre atómico de liquidación

```sql
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
```

Comportamiento:
- Idempotente: repetir el cierre de un período ya liquidado devuelve `settled: false, reason: 'sin_movimientos'`.
- Si `payout_due = 0` (comisión exactamente igual a adelantos), marca todo como liquidado sin crear movimiento de pago.
- El pago se registra como `commission_payout` con `is_settled = true`; no vuelve a entrar en ninguna liquidación.
- El lock `FOR UPDATE` sobre la ficha del profesional serializa cierres concurrentes.

### 8.6 Grants de las funciones sensibles

```sql
REVOKE ALL ON FUNCTION public.fn_staff_settlement_preview(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_settle_staff_commissions(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_staff_settlement_preview(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_settle_staff_commissions(UUID, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TEXT) TO authenticated;
```

---

## 9. SEMÁNTICA DE `is_settled` (H-07)

| `movement_type` | `is_settled = false` | `is_settled = true` |
|-----------------|----------------------|---------------------|
| `income` | Comisión aún no pagada al profesional | Comisión ya incluida en una liquidación cerrada |
| `staff_advance` | Adelanto aún no descontado | Adelanto ya descontado en una liquidación |
| `commission_payout` | (no aplica; el trigger fuerza `true`) | Pago de liquidación registrado |
| `expense` | Gasto registrado, fuera de liquidación | (no aplica; el trigger fuerza `false`) |

Lectura para la UI:
- "Por liquidar" = `v_staff_settlement_open.pending_commission`.
- "Adelantos a descontar" = `v_staff_settlement_open.pending_advances`.
- "A pagar" = `balance_due` (o `payout_due` del preview por período).
- El historial de liquidaciones se lista con `movement_type = 'commission_payout'`.

---

## 10. CHECKLIST DE APLICACIÓN Y VERIFICACIÓN

### 10.1 Orden de ejecución en Supabase

1. Sección 1 (extensión `btree_gist`).
2. Sección 2 (tablas) o sección 3.3 si la base ya existe.
3. Sección 3 (constraints de exclusión e integridad).
4. Sección 8.1 (trigger de cálculo) antes de insertar cualquier movimiento de caja.
5. Sección 4 (índices).
6. Sección 5 (helpers), 6 (RLS y grants), 7 y 8.4–8.6 (funciones y sus grants).
7. Ejecutar las pruebas de 10.2 con `set role anon` / `set role authenticated`.
8. Aplicar la migración de la sección 11 (`supabase/migrations/20261123_staff_login.sql`) o reejecutar `supabase/schema.sql` completo, que ya la incluye.

### 10.2 Pruebas mínimas (SQL Editor)

```sql
-- 1) anon no puede leer clientes ni turnos
SET ROLE anon;
SELECT count(*) FROM public.clients;          -- debe fallar por permisos / RLS
SELECT count(*) FROM public.appointments;     -- debe fallar por permisos / RLS
SELECT public.fn_public_shop('demo');         -- debe devolver solo datos públicos
RESET ROLE;

-- 2) reserva pública duplicada: el segundo insert debe dar 23P01
SET ROLE anon;
SELECT public.fn_public_create_booking(
  'demo', '<service_uuid>', '<staff_uuid>',
  now() + interval '2 days', 'Cliente Prueba', '5491112345678'
);
SELECT public.fn_public_create_booking(  -- mismo horario/profesional -> error
  'demo', '<service_uuid>', '<staff_uuid>',
  now() + interval '2 days', 'Otro Cliente', '5491187654321'
);
RESET ROLE;

-- 3) matemática de comisión (servicio 50%, descuento 2.000, insumos 1.500, bruto 20.000)
--    esperado: net_base 16500.00, comisión 8250.00, neto local 8250.00
SELECT net_base_amount, staff_commission_amount, shop_net_amount
  FROM public.cash_movements WHERE id = '<movement_uuid>';

-- 4) liquidación idempotente
SELECT public.fn_settle_staff_commissions('<shop_uuid>', '<staff_uuid>', now() - interval '30 days', now());
SELECT public.fn_settle_staff_commissions('<shop_uuid>', '<staff_uuid>', now() - interval '30 days', now());
-- la segunda llamada debe devolver settled = false / reason = sin_movimientos
```

### 10.3 Pendientes conscientes (fuera de T-000)

- RPC para que el profesional cambie el estado de **su** turno: resuelto en T-012 (§12.2).
- Actualización automática de `clients.last_visit_at` y `total_visits`: resuelto en T-013 (§12.3).
- Cancelación/reprogramación desde el link público con token de un solo uso (post-MVP).
- Rate limiting a nivel Edge Function / WAF, complementario al tope de 3 reservas pendientes por teléfono.

### 10.4 Modo offline tolerante (T-010)

El esquema **no cambia** para operar sin internet:

- `clients`, `appointments` y `cash_movements` aceptan un `id UUID` generado por el frontend, lo que permite reintentar inserts de forma idempotente.
- Los triggers y RPCs siguen calculando `net_base_amount`, `staff_commission_amount`, `shop_net_amount` y la liquidación. El frontend solo envía datos de entrada.
- Las restricciones existentes son la última defensa al sincronizar: `appointments_no_overlap` (`23P01`), checks de montos (`23514`), FKs (`23503`) y RLS (`42501`).
- No se agregan tablas de outbox en la base: la cola vive en IndexedDB del dispositivo y se vacía desde la app.
- Liquidaciones y configuración siguen requiriendo conexión; no se encolan.

Detalle de implementación y límites: `docs/06_OFFLINE.md`.

---

## 11. ACCESO DE PROFESIONALES (T-011)

Migración incremental: `supabase/migrations/20261123_staff_login.sql` (ya incluida al final de `supabase/schema.sql`).

### 11.1 Vínculo cuenta ↔ ficha

- El dueño comparte un **código de 8 caracteres** por profesional. El código vive en `staff_invites` (tabla separada) y no en `staff` para que el roster visible por otros profesionales no lo exponga.
- El profesional crea su cuenta con email/contraseña y, desde el onboarding, ingresa el código. La RPC `fn_claim_staff_invite(p_code)` valida el código, marca `staff.user_id = auth.uid()` y `staff_invites.claimed_at`.
- `staff.user_id` es `UNIQUE`: una cuenta puede estar vinculada a una sola ficha en toda la base. La RPC rechaza cuentas que ya administran un local (`shops.owner_id`) y códigos ya usados por otra cuenta.
- `fn_refresh_staff_invite(p_staff_id)` y `fn_unlink_staff_access(p_staff_id)` son solo para el dueño: rotan el código y desvinculan la cuenta actual.
- Un trigger (`trg_staff_invite_create`) crea la invitación al dar de alta un profesional.

### 11.2 RPCs de lectura del profesional

| Función | Devuelve |
|---------|----------|
| `fn_staff_context()` | Local + ficha propia del usuario logueado, o `NULL` si no es staff |
| `fn_my_agenda(p_date DATE)` | Turnos propios del día (sin cancelados) con cliente, servicio y estado, con el día calculado en `shops.timezone` |

Ambas son `SECURITY DEFINER`, exigen `auth.uid()` y no aceptan `shop_id` ni `staff_id` del cliente: la base deduce la ficha desde la sesión.

### 11.3 Límites del acceso

- El profesional **no** escribe turnos, caja, clientes, catálogo ni fichas de otros: sin políticas de escritura en `cash_movements`, `clients`, `catalog_items` ni `staff`.
- Las dos únicas escrituras permitidas son por RPC y sobre datos propios: `fn_set_my_appointment_status` (estado de sus turnos, §12.2) y `fn_update_my_profile` (foto y bio de su ficha, §12.4).
- No ve caja, equipo, configuración ni el link público como administrador.
- La agenda del profesional es online-only (la calcula la base).
- Si el dueño desactiva la ficha (`staff.is_active = false`), `fn_staff_context` sigue devolviendo el local con `staff_active = false` para que la pantalla muestre el aviso de acceso desactivado en lugar del alta de local; `fn_my_agenda` rechaza la consulta con `42501` hasta reactivarla.

---

## 12. ESTADOS DEL PROFESIONAL, VISITAS Y AJUSTES (T-012 a T-014)

Migración incremental: `supabase/migrations/20261123_appointments_settings.sql` (anexada al final de `supabase/schema.sql`). **Ejecutada en Supabase el 2026-11-23 (confirmado por el usuario).**

### 12.1 Columnas nuevas

| Tabla | Columna | Tipo / default | Uso |
|-------|---------|----------------|-----|
| `shops` | `description` | `TEXT` (≤ 280) | Bajada del salón en Ajustes y link público |
| `shops` | `whatsapp` | `TEXT` | WhatsApp de contacto |
| `shops` | `phone_landline` | `TEXT` | Teléfono fijo |
| `shops` | `phone_mobile` | `TEXT` | Celular |
| `shops` | `maps_url` | `TEXT` | Link de Google Maps provisto por el dueño |
| `shops` | `photo_url` | `TEXT` | Foto del salón (Storage) |
| `staff` | `photo_url` | `TEXT` | Foto de perfil del profesional |
| `staff` | `bio` | `TEXT` (≤ 240) | Descripción breve visible al reservar |
| `appointments` | `status_changed_by` | `UUID REFERENCES auth.users` | Auditoría del último cambio de estado |
| `appointments` | `status_changed_at` | `TIMESTAMPTZ` | Momento del último cambio de estado |

`shops.phone` se conserva por compatibilidad (recordatorios y mensajes); los campos nuevos son los que edita Ajustes. El dueño los escribe con la política `shops_owner_all` existente.

### 12.2 `fn_set_my_appointment_status(p_appointment_id UUID, p_status TEXT)`

`SECURITY DEFINER`, exige sesión y deduce la ficha por `staff.user_id = auth.uid()`. No acepta `staff_id` del cliente.

| Estado actual | `in_progress` | `completed` | `no_show` |
|---------------|---------------|-------------|-----------|
| `pending` / `confirmed` | ✅ | ❌ (pide iniciar) | ✅ |
| `in_progress` | idempotente | ✅ | ❌ |
| `completed` | ❌ | idempotente | ❌ |
| `no_show` | ❌ | ❌ | idempotente |
| `cancelled` | ❌ | ❌ | ❌ |

- Rechaza turnos de otro profesional y fichas inactivas con `42501`; transiciones inválidas con `22023`.
- Actualiza `status_changed_by` / `status_changed_at`; **no** genera movimientos de caja: la comisión nace al cobrar.
- No crea políticas de escritura: el profesional sigue sin `UPDATE` directo sobre `appointments`.

### 12.3 Visitas del cliente (`fn_sync_client_visits`)

Trigger `trg_appointments_client_visits` (`AFTER UPDATE OF status` en `appointments`) recalcula en `clients`:

- `total_visits` = turnos con `status = 'completed'`.
- `last_visit_at` = `max(starts_at)` de esos turnos.

Vale para cambios hechos por el dueño o por el profesional (RPC) y para reversiones (`completed → cancelled`). La migración incluye backfill de clientes existentes y pone en cero a quienes no tienen turnos completados. Estos campos ya son confiables para mostrar en la ficha; el listado de clientes mantiene además el conteo desde el historial para el detalle de visitas.

### 12.4 Perfil del profesional y Storage

- `fn_update_my_profile(p_photo_url TEXT, p_bio TEXT)`: solo la ficha propia, valida URL `http(s)` de hasta 500 caracteres y bio de hasta 240; devuelve `{ photo_url, bio }`.
- `fn_staff_context()` ahora devuelve `staff_photo` y `staff_bio`; `fn_public_shop()` devuelve los datos nuevos del salón y `photo_url`/`bio` de cada profesional activo.
- Bucket público **`media`** (`storage.buckets.public = true`). Convención de rutas:
  - `shops/<shop_id>/<archivo>` — solo el dueño (`public.is_shop_owner`).
  - `staff/<staff_id>/<archivo>` — solo la cuenta vinculada a esa ficha (`staff.user_id = auth.uid()`).
- Límite de subida desde la app: 5 MB, JPG/PNG/WebP. Las políticas de Storage no validan MIME/tamaño: el control es del cliente (el bucket es público de lectura).

### 12.5 Ajustes del salón y preferencias

- Datos, foto y contacto del salón se guardan en `shops` y son **online-only** (no pasan por la cola offline).
- Tipografía (`compact` / `normal` / `large`) y tema (`light` / `dark`) son preferencias **por dispositivo** en `localStorage` (`anstudios.preferences`), no viajan a la base.
- El link público conserva `fn_public_shop` como única fuente y ahora muestra foto, descripción, WhatsApp, fijo y "Cómo llegar" con `maps_url` o búsqueda por dirección.

### 12.6 Prueba rápida posterior a la migración

```sql
-- 1) un turno propio en curso, como profesional autenticado
SELECT public.fn_set_my_appointment_status('<appointment_uuid>', 'in_progress');
-- 2) completar y verificar visitas recalculadas
SELECT public.fn_set_my_appointment_status('<appointment_uuid>', 'completed');
SELECT id, total_visits, last_visit_at FROM public.clients WHERE id = '<client_uuid>';
-- 3) un turno ajeno debe fallar con 42501
-- 4) perfil propio
SELECT public.fn_update_my_profile('https://…/foto.jpg', 'Barbero especialista en fades.');
SELECT public.fn_staff_context();
```

---

## 13. GESTIÓN PÚBLICA DEL TURNO (T-016)

Migración incremental: `supabase/migrations/20261123_public_manage.sql` (anexada al final de `supabase/schema.sql`). **Ejecutada en Supabase el 2026-11-23 (confirmado por el usuario).**

### 13.1 Token de capacidad

- `appointments.public_token UUID NOT NULL DEFAULT gen_random_uuid()` con índice único `appointments_public_token_key`.
- Es una **capacidad**: quien tiene el link puede gestionar ese turno y solo ese. No hay login de cliente ni se expone ninguna tabla al rol `anon`; todas las operaciones pasan por RPCs `SECURITY DEFINER`.
- `fn_public_create_booking` ahora devuelve `public_token` además del `appointment_id`, para que la pantalla de confirmación arme el link.

### 13.2 RPCs

| Función | Devuelve / hace |
|---------|-----------------|
| `fn_public_manage_appointment(p_token UUID)` | Local (slug, nombre, dirección, teléfonos, Maps, timezone) + turno (estado, fechas, servicio, profesional, nombre del cliente, notas, `can_manage`) |
| `fn_public_cancel_appointment(p_token UUID)` | Pasa el turno a `cancelled` si sigue `pending`/`confirmed` y no empezó |
| `fn_public_reschedule_appointment(p_token UUID, p_starts_at TIMESTAMPTZ)` | Mueve fecha/hora respetando duración del servicio, horario del local, grilla y 90 días; si estaba `confirmed` vuelve a `pending` |

Reglas:

- `can_manage` es `true` solo con estado `pending`/`confirmed` y `starts_at > now()`.
- Cancelar es idempotente por estado: un turno ya cancelado/completado/ausente devuelve `22023`; en curso o pasado también.
- Reprogramar exige al menos 30 minutos de anticipación (igual que la reserva) y reutiliza la restricción `appointments_no_overlap`: un choque devuelve `23P01`, que la UI muestra como "ese horario acaba de ocuparse".
- Ni cancelar ni reprogramar generan dinero; si el turno estaba cobrado, el movimiento de caja queda como está y el local lo resuelve en Caja.
- Cambiar el estado dispara `trg_appointments_client_visits`, así que las visitas se recalculan también cuando el cliente cancela.

### 13.3 Prueba rápida

```sql
-- 1) crear una reserva pública y guardar el token que devuelve
SELECT public.fn_public_create_booking('<slug>', '<service_uuid>', '<staff_uuid>',
  now() + interval '3 days', 'Prueba', '1155555555', NULL);
-- 2) consultar
SELECT public.fn_public_manage_appointment('<token>');
-- 3) reprogramar a otro horario libre
SELECT public.fn_public_reschedule_appointment('<token>', '<nuevo_starts_at>');
-- 4) cancelar
SELECT public.fn_public_cancel_appointment('<token>');
-- 5) el mismo token ya no permite cancelar (22023)
```

### 13.4 Búsqueda de turno existente por teléfono/nombre (T-024)

Migración incremental: `supabase/migrations/20261126_public_find_appointments.sql` (anexada al final de `supabase/schema.sql`). **Pendiente de ejecutar en Supabase.**

- `fn_public_find_appointments(p_slug TEXT, p_phone TEXT, p_name TEXT)` devuelve los turnos activos de un local que coincidan con el teléfono (normalizado a dígitos) y/o con el nombre del cliente (coincidencia parcial, case-insensitive), con `public_token`, fechas, servicio y profesional. Al menos uno de los dos parámetros debe venir.
- No expone tablas al rol `anon`: solo la RPC `SECURITY DEFINER`, con las mismas validaciones de local bloqueado (`22023`) que el resto del flujo público.
- La UI del link público usa el resultado para ofrecer "Gestionar mi turno" (`/turno/:token`) sin requerir login.

## 14. FEED DE CALENDARIO (T-020)

Migración incremental: `supabase/migrations/20261123_calendar_feed.sql` (anexada al final de `supabase/schema.sql`). Requiere ejecutar el SQL y desplegar la Edge Function (ver §14.2).

### 14.1 Token de capacidad por profesional

- `staff.calendar_token UUID NOT NULL DEFAULT gen_random_uuid()` con índice único `idx_staff_calendar_token`.
- Es una capacidad de solo lectura: el link suscribe la agenda de ese profesional. No da acceso de escritura ni a otras tablas.
- `fn_calendar_token(p_staff_id UUID DEFAULT NULL)` devuelve el token; con `NULL` usa la ficha del profesional logueado. Solo el dueño del local o el propio profesional pueden leerlo (`42501` en el resto).
- `fn_rotate_calendar_token(p_staff_id UUID DEFAULT NULL)` regenera el token e invalida el link anterior de inmediato.
- `listStaff` ya no hace `select *`: pide columnas explícitas sin `calendar_token` para que el token no quede en el caché offline del dispositivo.
- El feed incluye turnos entre -90 y +90 días. Los cancelados se publican como `STATUS:CANCELLED`; los ausentes llevan "(no asistió)" en el título. Solo expone nombre del cliente y servicio, nunca teléfono ni notas.

### 14.2 Edge Function `calendar-feed`

- Código: `supabase/functions/calendar-feed/index.ts` (Deno).
- URL: `<SUPABASE_URL>/functions/v1/calendar-feed?token=<calendar_token>`.
- Usa `SUPABASE_URL` y `SUPABASE_SERVICE_ROLE_KEY`, que Supabase inyecta en las Edge Functions; no hay secretos extra.
- Se despliega **sin verificación de JWT**, porque Google Calendar consulta la URL de forma anónima y la autorización es el token:

```bash
supabase functions deploy calendar-feed --no-verify-jwt
```

- Respuesta `text/calendar`, cacheada 15 minutos. Google refresca los feeds externos cada varias horas, no es tiempo real.

### 14.3 Prueba rápida

```bash
# 1) obtener el token desde la app (Equipo → Calendario del teléfono)
# 2) pedir el feed con el token
curl -i "https://<project-ref>.supabase.co/functions/v1/calendar-feed?token=<uuid>"
# 3) suscribirse en Google Calendar → Otros calendarios → Desde URL
# 4) regenerar el token y verificar que la URL anterior devuelve 404
```

---

## 15. LICENCIAS: SUSPENSIÓN, PRUEBA Y SUPERADMIN (T-022)

Migración: `supabase/migrations/20261123_platform_licensing.sql` (también anexada a `supabase/schema.sql`).

### 15.1 Columnas nuevas en `shops`

| Columna | Tipo | Uso |
|---------|------|-----|
| `is_suspended` | `BOOLEAN NOT NULL DEFAULT false` | Suspensión manual por impago |
| `suspended_at` | `TIMESTAMPTZ` | Cuándo se suspendió |
| `suspension_note` | `TEXT` (≤ 200) | Motivo visible para el dueño |
| `trial_ends_at` | `TIMESTAMPTZ` | Fin de la prueba gratuita (solo la otorga el superadmin) |

Estado efectivo: `suspended` gana sobre todo; si hay `trial_ends_at` vencido → `trial_expired`; si hay prueba vigente → `trial`; si no → `active`.

### 15.2 Superadmins

```sql
CREATE TABLE public.platform_admins (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

RLS habilitada **sin políticas** y grants revocados a `anon`/`authenticated`: solo se consulta desde funciones `SECURITY DEFINER`. Alta manual (una vez por persona):

```sql
INSERT INTO public.platform_admins (user_id)
SELECT id FROM auth.users WHERE email = 'tu@email.com'
ON CONFLICT DO NOTHING;
```

### 15.3 Funciones

| Función | Devuelve | Notas |
|---------|----------|-------|
| `fn_shop_usable(uuid)` | `BOOLEAN` | `true` si no está suspendido y la prueba (si existe) sigue vigente |
| `fn_shop_access(uuid)` | `JSONB` | `state`, `trial_ends_at`, `days_left`, `suspended_at`, `suspension_note` |
| `fn_is_platform_admin()` | `BOOLEAN` | Según `platform_admins` y `auth.uid()` |
| `fn_platform_me()` | `JSONB` | `{ is_admin, has_shop }` para enrutar la app |
| `fn_platform_shops()` | `JSONB` | Todos los locales con email del dueño, conteos, último turno y licencia |
| `fn_platform_set_suspension(uuid, boolean, text)` | `JSONB` | Suspende/habilita y guarda el motivo |
| `fn_platform_set_trial(uuid, int)` | `JSONB` | `90` otorga/renueva; `0` quita la prueba |

Todas las de plataforma validan `fn_is_platform_admin()` y devuelven `42501` si no.

### 15.4 Bloqueo efectivo

- **RLS restrictiva** (`AS RESTRICTIVE`) en `staff`, `catalog_items`, `clients`, `appointments`, `cash_movements` y `staff_invites`: con el local bloqueado, el dueño y el profesional no pueden leer ni escribir esas tablas. `shops` queda legible para mostrar el motivo en la app.
- **Link público:** `fn_public_shop` devuelve vacío y `fn_public_availability` responde `22023`; el trigger `trg_appointments_shop_access` rechaza cualquier alta de turno (también reprogramaciones públicas) con `22023`.
- **Feed ICS:** la Edge Function devuelve `404` si el local está suspendido o con prueba vencida.
- **App:** el dueño ve la pantalla "local suspendido / prueba vencida" y el profesional el mismo aviso desde `fn_staff_context().shop_access`.
- **Columnas protegidas:** el trigger `trg_shops_guard_license` rechaza (`42501`) cualquier cambio desde un JWT `authenticated` a `is_suspended`, `suspended_at`, `suspension_note` o `trial_ends_at` que no venga de un superadmin. `service_role` y el SQL Editor siguen pudiendo operar manualmente.

Limitación consciente: las RPCs `SECURITY DEFINER` de liquidación y estados de turno no verifican la licencia por sí mismas; el bloqueo operativo está en la app, en RLS y en las reservas. Si se necesita un corte total a nivel API, agregar el chequeo `fn_shop_usable` en esas RPCs.

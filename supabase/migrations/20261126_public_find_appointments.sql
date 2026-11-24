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

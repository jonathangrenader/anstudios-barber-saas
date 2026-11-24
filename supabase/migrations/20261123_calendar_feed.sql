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

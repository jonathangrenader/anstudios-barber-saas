import { supabase } from './supabase'
import type {
  SettlementCloseReason,
  SettlementCloseResult,
  SettlementPreview,
  StaffSettlementSummary,
} from '../types/settlement'
import type { PaymentMethod } from '../types/cash'

type ErrorLike = { code?: string; message: string }
type JsonRow = Record<string, unknown>

function toNumber(value: unknown): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function toIso(value: unknown): string {
  return typeof value === 'string' ? value : new Date(0).toISOString()
}

function settlementErrorMessage(error: ErrorLike, fallback: string): Error {
  if (error.code === '42501') {
    return new Error('No tenés permiso para liquidar comisiones.')
  }
  if (error.code === '22023') {
    return new Error(error.message || 'El período de liquidación no es válido.')
  }
  return new Error(error.message || fallback)
}

function mapPreview(row: JsonRow): SettlementPreview {
  return {
    shop_id: String(row.shop_id ?? ''),
    staff_id: String(row.staff_id ?? ''),
    period_start: toIso(row.period_start),
    period_end: toIso(row.period_end),
    income_count: toNumber(row.income_count),
    gross_total: toNumber(row.gross_total),
    discount_total: toNumber(row.discount_total),
    supply_total: toNumber(row.supply_total),
    net_base_total: toNumber(row.net_base_total),
    commission_total: toNumber(row.commission_total),
    advances_count: toNumber(row.advances_count),
    advances_total: toNumber(row.advances_total),
    payout_due: toNumber(row.payout_due),
  }
}

export async function listStaffSettlements(
  shopId: string,
): Promise<StaffSettlementSummary[]> {
  const { data, error } = await supabase
    .from('v_staff_settlement_open')
    .select('*')
    .eq('shop_id', shopId)
    .order('staff_name')

  if (error) throw new Error(error.message || 'No pudimos cargar las liquidaciones.')

  return ((data ?? []) as JsonRow[]).map((row) => ({
    shop_id: String(row.shop_id ?? ''),
    staff_id: String(row.staff_id ?? ''),
    staff_name: String(row.staff_name ?? ''),
    pending_commission: toNumber(row.pending_commission),
    pending_advances: toNumber(row.pending_advances),
    pending_income_count: toNumber(row.pending_income_count),
    balance_due: toNumber(row.balance_due),
  }))
}

export async function previewStaffSettlement({
  shopId,
  staffId,
  periodStart,
  periodEnd,
}: {
  shopId: string
  staffId: string
  periodStart: string
  periodEnd: string
}): Promise<SettlementPreview> {
  const { data, error } = await supabase.rpc('fn_staff_settlement_preview', {
    p_shop_id: shopId,
    p_staff_id: staffId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
  })

  if (error) throw settlementErrorMessage(error, 'No pudimos calcular la liquidación.')
  if (!data || typeof data !== 'object') {
    throw new Error('La liquidación no devolvió datos.')
  }

  return mapPreview(data as JsonRow)
}

export async function closeStaffSettlement({
  shopId,
  staffId,
  periodStart,
  periodEnd,
  paymentMethod,
  notes,
}: {
  shopId: string
  staffId: string
  periodStart: string
  periodEnd: string
  paymentMethod: PaymentMethod
  notes: string | null
}): Promise<SettlementCloseResult> {
  const { data, error } = await supabase.rpc('fn_settle_staff_commissions', {
    p_shop_id: shopId,
    p_staff_id: staffId,
    p_period_start: periodStart,
    p_period_end: periodEnd,
    p_payment_method: paymentMethod,
    p_notes: notes,
  })

  if (error) throw settlementErrorMessage(error, 'No pudimos cerrar la liquidación.')
  if (!data || typeof data !== 'object') {
    throw new Error('El cierre no devolvió datos.')
  }

  const row = data as JsonRow
  const reason =
    row.reason === 'sin_movimientos' || row.reason === 'saldo_a_favor_del_local'
      ? (row.reason as SettlementCloseReason)
      : undefined

  return {
    ...mapPreview(row),
    settled: row.settled === true,
    reason,
    advances_deducted:
      row.advances_deducted === undefined ? undefined : toNumber(row.advances_deducted),
    payout_amount:
      row.payout_amount === undefined ? undefined : toNumber(row.payout_amount),
    payout_id: typeof row.payout_id === 'string' ? row.payout_id : null,
  }
}

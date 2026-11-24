export interface StaffSettlementSummary {
  shop_id: string
  staff_id: string
  staff_name: string
  pending_commission: number
  pending_advances: number
  pending_income_count: number
  balance_due: number
}

export interface SettlementPreview {
  shop_id: string
  staff_id: string
  period_start: string
  period_end: string
  income_count: number
  gross_total: number
  discount_total: number
  supply_total: number
  net_base_total: number
  commission_total: number
  advances_count: number
  advances_total: number
  payout_due: number
}

export type SettlementCloseReason = 'sin_movimientos' | 'saldo_a_favor_del_local'

export interface SettlementCloseResult extends SettlementPreview {
  settled: boolean
  reason?: SettlementCloseReason
  advances_deducted?: number
  payout_amount?: number
  payout_id?: string | null
}

import type { CatalogItemType } from './catalog'

export type CashMovementType = 'income' | 'expense' | 'staff_advance' | 'commission_payout'

export type PaymentMethod = 'cash' | 'transfer' | 'card' | 'qr'

export interface CashMovement {
  id: string
  shop_id: string
  appointment_id: string | null
  staff_id: string | null
  item_id: string | null
  movement_type: CashMovementType
  description: string
  payment_method: PaymentMethod
  gross_amount: number
  discount_amount: number
  supply_deduction: number
  net_base_amount: number
  commission_pct_applied: number | null
  staff_commission_amount: number
  shop_net_amount: number
  is_settled: boolean
  movement_date: string
  created_at: string
}

export type CashMovementView = CashMovement & {
  staff: { name: string; color_hex: string } | null
  item: { name: string; type: CatalogItemType } | null
  appointment: { client_name_snapshot: string; starts_at: string } | null
  sync_status?: 'pending' | 'failed'
}

export interface CashIncomeInput {
  appointment_id: string | null
  staff_id: string
  item_id: string | null
  description: string
  payment_method: PaymentMethod
  gross_amount: number
  discount_amount: number
  supply_deduction: number
  movement_date: string
}

export interface CashOutflowInput {
  movement_type: 'expense' | 'staff_advance'
  staff_id: string | null
  description: string
  payment_method: PaymentMethod
  gross_amount: number
  movement_date: string
}

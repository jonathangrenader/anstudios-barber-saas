import type { AppointmentSource, AppointmentStatus } from './appointment'
import type { ShopAccess } from './shop'

export interface StaffMember {
  id: string
  shop_id: string
  user_id: string | null
  name: string
  role: string
  phone: string | null
  commission_pct: number
  product_commission_pct: number
  is_active: boolean
  color_hex: string
  photo_url: string | null
  bio: string | null
  can_book_appointments: boolean
  working_days: number[] | null
  work_start_time: string | null
  work_end_time: string | null
  created_at: string
}

export type StaffInput = Pick<
  StaffMember,
  | 'name'
  | 'role'
  | 'phone'
  | 'commission_pct'
  | 'product_commission_pct'
  | 'is_active'
  | 'color_hex'
  | 'can_book_appointments'
>

/** Código de un solo uso que el dueño comparte con el profesional. */
export interface StaffInvite {
  staff_id: string
  shop_id: string
  code: string
  claimed_at: string | null
  created_at: string
}

/** Local + ficha propia del profesional logueado. */
export interface StaffContext {
  staff_id: string
  staff_name: string
  staff_role: string
  staff_color: string
  staff_active: boolean
  staff_photo: string | null
  staff_bio: string | null
  shop_id: string
  shop_name: string
  shop_slug: string
  shop_address: string | null
  shop_phone: string | null
  shop_timezone: string
  shop_open_time: string
  shop_close_time: string
  shop_slot_duration_min?: number
  staff_can_book_appointments?: boolean
  staff_working_days?: number[] | null
  staff_work_start_time?: string | null
  staff_work_end_time?: string | null
  shop_professional_booking_mode?: 'disabled' | 'per_staff' | 'all'
  shop_public_booking_enabled?: boolean
  shop_professionals_can_manage_appointments?: boolean
  shop_professionals_can_book?: boolean
  shop_access?: ShopAccess | null
}

/** Turno propio que devuelve `fn_my_agenda`. */
export interface StaffAgendaItem {
  id: string
  starts_at: string
  ends_at: string
  status: AppointmentStatus
  source: AppointmentSource
  reminder_sent: boolean
  notes: string | null
  client_name: string
  client_phone: string
  service_name: string | null
}

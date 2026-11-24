export interface PlatformMe {
  is_admin: boolean
  has_shop: boolean
}

/** Local visto desde el panel de plataforma (incluye datos de cobro/uso). */
export interface PlatformShop {
  id: string
  name: string
  slug: string
  address: string | null
  created_at: string
  owner_email: string | null
  is_suspended: boolean
  suspended_at: string | null
  suspension_note: string | null
  trial_ends_at: string | null
  staff_count: number
  appointments_count: number
  last_appointment_at: string | null
  is_mine: boolean
}

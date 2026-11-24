export interface Shop {
  id: string
  owner_id: string
  name: string
  slug: string
  phone: string | null
  address: string | null
  description: string | null
  whatsapp: string | null
  phone_landline: string | null
  phone_mobile: string | null
  maps_url: string | null
  photo_url: string | null
  timezone: string
  open_time: string
  close_time: string
  slot_duration_min: number
  professionals_can_book: boolean
  professional_booking_mode: 'disabled' | 'per_staff' | 'all'
  public_booking_enabled: boolean
  professionals_can_manage_appointments: boolean
  is_suspended: boolean
  suspended_at: string | null
  suspension_note: string | null
  trial_ends_at: string | null
  created_at: string
}

export type ShopAccessState = 'active' | 'trial' | 'trial_expired' | 'suspended'

/** Estado efectivo de licencia (lo calcula la base y también la app). */
export interface ShopAccess {
  state: ShopAccessState
  trial_ends_at: string | null
  days_left: number
  suspended_at: string | null
  suspension_note: string | null
}

export type ShopInput = Pick<
  Shop,
  | 'name'
  | 'slug'
  | 'phone'
  | 'address'
  | 'timezone'
  | 'open_time'
  | 'close_time'
  | 'slot_duration_min'
> &
  Partial<
    Pick<
      Shop,
      'description' | 'whatsapp' | 'phone_landline' | 'phone_mobile' | 'maps_url' | 'photo_url' |      'professionals_can_book' | 'professional_booking_mode' | 'public_booking_enabled' | 'professionals_can_manage_appointments'
    >
  >

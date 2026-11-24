export interface PublicShop {
  name: string
  slug: string
  address: string | null
  phone: string | null
  description: string | null
  whatsapp: string | null
  phone_landline: string | null
  phone_mobile: string | null
  maps_url: string | null
  photo_url: string | null
  open_time: string
  close_time: string
  slot_duration_min: number
  timezone: string
}

export interface PublicService {
  id: string
  name: string
  price: number
  duration_min: number
}

export interface PublicStaff {
  id: string
  name: string
  color_hex: string
  photo_url: string | null
  bio: string | null
}

export interface PublicShopData {
  shop: PublicShop
  services: PublicService[]
  staff: PublicStaff[]
}

export interface PublicAvailabilitySlot {
  staff_id: string
  slot_start: string
  slot_end: string
}

export interface PublicBookingResult {
  appointment_id: string
  public_token: string
  starts_at: string
  ends_at: string
  service_name: string
  staff_name: string
  shop_name: string
  status: string
}

export interface ManagedShop {
  slug: string
  name: string
  address: string | null
  phone: string | null
  whatsapp: string | null
  maps_url: string | null
  timezone: string
}

export interface ManagedAppointment {
  id: string
  status: string
  starts_at: string
  ends_at: string
  service_id: string | null
  staff_id: string | null
  service_name: string | null
  staff_name: string | null
  client_name: string
  notes: string | null
  can_manage: boolean
}

export interface ManagedBooking {
  shop: ManagedShop
  appointment: ManagedAppointment
}

export interface RescheduleResult {
  appointment_id: string
  starts_at: string
  ends_at: string
  status: string
  service_name: string | null
  staff_name: string | null
  shop_name: string
}

export interface PublicFoundAppointment {
  appointment_id: string
  public_token: string
  starts_at: string
  ends_at: string
  status: string
  service_name: string | null
  staff_name: string | null
  client_name: string
}

export interface PublicBookingInput {
  slug: string
  serviceId: string
  staffId: string
  startsAt: string
  clientName: string
  clientPhone: string
  notes: string
}

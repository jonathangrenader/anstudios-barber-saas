export type AppointmentStatus =
  | 'pending'
  | 'confirmed'
  | 'in_progress'
  | 'completed'
  | 'cancelled'
  | 'no_show'

export type AppointmentSource = 'admin' | 'public_link' | 'walk_in'

export interface Appointment {
  id: string
  shop_id: string
  client_id: string | null
  staff_id: string
  service_id: string | null
  client_name_snapshot: string
  client_phone_snapshot: string
  starts_at: string
  ends_at: string
  status: AppointmentStatus
  source: AppointmentSource
  reminder_sent: boolean
  notes: string | null
  created_at: string
}

export type AppointmentView = Appointment & {
  service: { name: string } | null
  staff: { name: string; color_hex: string } | null
  sync_status?: 'pending' | 'failed'
}

export interface NewAppointmentInput {
  client_id: string | null
  staff_id: string
  service_id: string | null
  client_name_snapshot: string
  client_phone_snapshot: string
  starts_at: string
  ends_at: string
  status: 'pending' | 'confirmed'
  source: 'admin' | 'walk_in'
  notes: string | null
}

export interface ClientVisit {
  id: string
  starts_at: string
  ends_at: string
  status: AppointmentStatus
  notes: string | null
  service: { name: string } | null
  staff: { name: string; color_hex: string } | null
}

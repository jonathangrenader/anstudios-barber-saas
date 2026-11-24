import { supabase } from './supabase'
import { normalizePhone } from './clients'
import type {
  ManagedBooking,
  PublicAvailabilitySlot,
  PublicBookingInput,
  PublicBookingResult,
  PublicFoundAppointment,
  PublicShopData,
  RescheduleResult,
} from '../types/publicBooking'

type RpcError = { code?: string; message: string }

export class PublicBookingError extends Error {
  readonly code?: string

  constructor(message: string, code?: string) {
    super(message)
    this.name = 'PublicBookingError'
    this.code = code
  }
}

function publicErrorMessage(error: RpcError, fallback: string): PublicBookingError {
  if (error.code === '23P01') {
    return new PublicBookingError(
      'Ese horario acaba de ocuparse. Elegí otro horario disponible.',
      error.code,
    )
  }
  if (error.code === '22023') {
    return new PublicBookingError(error.message || fallback, error.code)
  }
  if (error.code === '42501') {
    return new PublicBookingError('No tenés permiso para esta acción.', error.code)
  }
  if (error.code === 'PGRST202' || /could not find the function/i.test(error.message)) {
    return new PublicBookingError(
      'Esta función online todavía no está habilitada para este local.',
      error.code,
    )
  }
  return new PublicBookingError(fallback, error.code)
}

export async function getPublicShop(slug: string): Promise<PublicShopData | null> {
  const { data, error } = await supabase.rpc('fn_public_shop', { p_slug: slug })

  if (error) throw publicErrorMessage(error, 'No pudimos cargar el local.')
  if (!data || typeof data !== 'object') return null

  const payload = data as Partial<PublicShopData>
  if (!payload.shop || !Array.isArray(payload.services) || !Array.isArray(payload.staff)) {
    return null
  }

  return payload as PublicShopData
}

export async function listPublicAvailability(
  slug: string,
  serviceId: string,
  day: string,
  staffId: string,
): Promise<PublicAvailabilitySlot[]> {
  const { data, error } = await supabase.rpc('fn_public_availability', {
    p_slug: slug,
    p_service_id: serviceId,
    p_day: day,
    p_staff_id: staffId,
  })

  if (error) throw publicErrorMessage(error, 'No pudimos verificar la disponibilidad.')

  // La RPC permite días hasta hoy + 90; al reservar también valida 90 días exactos.
  // Filtramos el borde para no mostrar horarios que el guardado rechazaría.
  const limit = Date.now() + 90 * 24 * 60 * 60 * 1000
  const slots = ((data ?? []) as PublicAvailabilitySlot[]).filter(
    (slot) => new Date(slot.slot_start).getTime() <= limit,
  )

  return slots.sort((a, b) => a.slot_start.localeCompare(b.slot_start))
}

export async function createPublicBooking(
  input: PublicBookingInput,
): Promise<PublicBookingResult> {
  const { data, error } = await supabase.rpc('fn_public_create_booking', {
    p_slug: input.slug,
    p_service_id: input.serviceId,
    p_staff_id: input.staffId,
    p_starts_at: input.startsAt,
    p_client_name: input.clientName.trim(),
    p_client_phone: normalizePhone(input.clientPhone),
    p_notes: input.notes.trim() || null,
  })

  if (error) throw publicErrorMessage(error, 'No pudimos guardar la reserva.')
  if (!data || typeof data !== 'object') {
    throw new PublicBookingError('No pudimos guardar la reserva.')
  }

  return data as PublicBookingResult
}

export async function findPublicAppointments(
  slug: string,
  phone: string,
  name: string,
): Promise<PublicFoundAppointment[]> {
  const { data, error } = await supabase.rpc('fn_public_find_appointments', {
    p_slug: slug,
    p_phone: phone || null,
    p_name: name || null,
  })

  if (error) throw publicErrorMessage(error, 'No pudimos buscar tus turnos.')
  if (!Array.isArray(data)) return []
  return data as PublicFoundAppointment[]
}

export async function getManagedBooking(token: string): Promise<ManagedBooking> {
  const { data, error } = await supabase.rpc('fn_public_manage_appointment', {
    p_token: token,
  })

  if (error) throw publicErrorMessage(error, 'No pudimos cargar tu turno.')
  if (!data || typeof data !== 'object') {
    throw new PublicBookingError('No pudimos cargar tu turno.')
  }

  return data as ManagedBooking
}

export async function cancelPublicBooking(token: string): Promise<void> {
  const { error } = await supabase.rpc('fn_public_cancel_appointment', { p_token: token })
  if (error) throw publicErrorMessage(error, 'No pudimos cancelar el turno.')
}

export async function reschedulePublicBooking(
  token: string,
  startsAt: string,
): Promise<RescheduleResult> {
  const { data, error } = await supabase.rpc('fn_public_reschedule_appointment', {
    p_token: token,
    p_starts_at: startsAt,
  })

  if (error) throw publicErrorMessage(error, 'No pudimos cambiar el horario.')
  if (!data || typeof data !== 'object') {
    throw new PublicBookingError('No pudimos cambiar el horario.')
  }

  return data as RescheduleResult
}

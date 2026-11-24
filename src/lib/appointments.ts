import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'
import { cachedQuery } from './offline/cache'
import { addOutbox, getOutbox } from './offline/db'
import { emitOutboxChanged } from './offline/events'
import { cacheKeys } from './offline/keys'
import { isBrowserOffline, isNetworkError, newLocalId } from './offline/network'
import { overlayAppointments } from './offline/pending'
import type { MutationResult } from './offline/types'
import type {
  AppointmentStatus,
  AppointmentView,
  NewAppointmentInput,
} from '../types/appointment'

export async function listAppointmentsForDay(
  shopId: string,
  startIso: string,
  endIso: string,
): Promise<AppointmentView[]> {
  const rows = await cachedQuery(
    cacheKeys.agenda(shopId, startIso, endIso),
    async () => {
      const { data, error } = await supabase
        .from('appointments')
        .select(
          '*, service:catalog_items(name), staff:staff(name, color_hex)',
        )
        .eq('shop_id', shopId)
        .gte('starts_at', startIso)
        .lt('starts_at', endIso)
        .order('starts_at')
        .limit(200)

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar la agenda.'))
      return (data ?? []) as unknown as AppointmentView[]
    },
    'Sin conexión y sin agenda guardada para este día. Conectate una vez para poder consultarla offline.',
  )

  return overlayAppointments(shopId, rows, startIso, endIso)
}

export async function createAppointment(
  shopId: string,
  input: NewAppointmentInput,
): Promise<MutationResult> {
  const id = newLocalId()
  const createdAt = new Date().toISOString()
  const payload = {
    ...input,
    id,
    shop_id: shopId,
    created_at: createdAt,
    reminder_sent: false,
  }

  const queued = await getOutbox(shopId)
  const pendingClient =
    input.client_id !== null &&
    queued.some(
      (item) => item.type === 'client.create' && item.payload.id === input.client_id,
    )

  if (!isBrowserOffline() && !pendingClient) {
    try {
      const { error } = await supabase.from('appointments').insert({
        id: payload.id,
        shop_id: payload.shop_id,
        client_id: payload.client_id,
        staff_id: payload.staff_id,
        service_id: payload.service_id,
        client_name_snapshot: payload.client_name_snapshot,
        client_phone_snapshot: payload.client_phone_snapshot,
        starts_at: payload.starts_at,
        ends_at: payload.ends_at,
        status: payload.status,
        source: payload.source,
        notes: payload.notes,
      })

      if (error?.code === '23P01') {
        throw new Error('Ese horario acaba de ocuparse para ese profesional. Elegí otro.')
      }
      if (error) throw new Error(dbErrorMessage(error, 'No pudimos crear el turno.'))
      return { queued: false, id }
    } catch (error) {
      if (!isNetworkError(error)) throw error
    }
  }

  await addOutbox({
    id: newLocalId(),
    shopId,
    createdAt,
    attempts: 0,
    status: 'pending',
    lastError: null,
    type: 'appointment.create',
    payload,
  })
  emitOutboxChanged()
  return { queued: true, id }
}

export async function listPendingAppointments(
  shopId: string,
): Promise<AppointmentView[]> {
  const { data, error } = await supabase
    .from('appointments')
    .select('*, service:catalog_items(name), staff:staff(name, color_hex)')
    .eq('shop_id', shopId)
    .eq('status', 'pending')
    .order('starts_at', { ascending: true })
    .limit(50)

  if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar los turnos pendientes.'))
  return (data ?? []) as unknown as AppointmentView[]
}

export async function rejectAppointment(
  id: string,
  shopId: string,
  reason: string,
): Promise<MutationResult> {
  const trimmed = reason.trim()
  const { data: current } = await supabase
    .from('appointments')
    .select('notes')
    .eq('id', id)
    .eq('shop_id', shopId)
    .maybeSingle()

  const existingNotes = (current as { notes?: string | null } | null)?.notes
  const nextNotes = trimmed
    ? existingNotes
      ? `${existingNotes}\n\nMotivo de rechazo: ${trimmed}`
      : `Motivo de rechazo: ${trimmed}`
    : existingNotes ?? null

  if (!isBrowserOffline()) {
    try {
      const { error } = await supabase
        .from('appointments')
        .update({ status: 'cancelled', notes: nextNotes })
        .eq('id', id)
        .eq('shop_id', shopId)

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos rechazar el turno.'))
      return { queued: false, id }
    } catch (error) {
      if (!isNetworkError(error)) throw error
    }
  }

  await addOutbox({
    id: newLocalId(),
    shopId,
    createdAt: new Date().toISOString(),
    attempts: 0,
    status: 'pending',
    lastError: null,
    type: 'appointment.status',
    payload: { id, status: 'cancelled' },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

export async function updateAppointmentStatus(
  id: string,
  shopId: string,
  status: AppointmentStatus,
): Promise<MutationResult> {
  if (!isBrowserOffline()) {
    try {
      const { error } = await supabase
        .from('appointments')
        .update({ status })
        .eq('id', id)
        .eq('shop_id', shopId)

      if (error?.code === '23P01') {
        throw new Error('No se puede reabrir: otro turno activo ya ocupa este horario.')
      }
      if (error) throw new Error(dbErrorMessage(error, 'No pudimos actualizar el turno.'))
      return { queued: false, id }
    } catch (error) {
      if (!isNetworkError(error)) throw error
    }
  }

  await addOutbox({
    id: newLocalId(),
    shopId,
    createdAt: new Date().toISOString(),
    attempts: 0,
    status: 'pending',
    lastError: null,
    type: 'appointment.status',
    payload: { id, status },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

export async function reassignAppointment(
  appointmentId: string,
  newStaffId: string,
): Promise<void> {
  const { error } = await supabase.rpc('fn_reassign_appointment', {
    p_appointment_id: appointmentId,
    p_new_staff_id: newStaffId,
  })
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos reasignar el turno.'))
}

export async function rescheduleAppointment(
  appointmentId: string,
  newStartsAt: string,
): Promise<{ starts_at: string; ends_at: string }> {
  const { data, error } = await supabase.rpc('fn_reschedule_appointment_internal', {
    p_appointment_id: appointmentId,
    p_new_starts_at: newStartsAt,
  })
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos reprogramar el turno.'))
  return data as { starts_at: string; ends_at: string }
}

export async function markReminderSent(id: string, shopId: string): Promise<MutationResult> {
  if (!isBrowserOffline()) {
    try {
      const { error } = await supabase
        .from('appointments')
        .update({ reminder_sent: true })
        .eq('id', id)
        .eq('shop_id', shopId)

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos marcar el recordatorio.'))
      return { queued: false, id }
    } catch (error) {
      if (!isNetworkError(error)) throw error
    }
  }

  await addOutbox({
    id: newLocalId(),
    shopId,
    createdAt: new Date().toISOString(),
    attempts: 0,
    status: 'pending',
    lastError: null,
    type: 'appointment.reminder',
    payload: { id },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

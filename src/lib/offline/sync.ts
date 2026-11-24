import { supabase } from '../supabase'
import {
  deleteOutbox,
  getOutbox,
  getOutboxItem,
  getOutboxSnapshot,
  remapClientInOutbox,
  retryFailedOutbox,
  updateOutbox,
} from './db'
import { emitOutboxChanged, emitSyncComplete } from './events'
import { isBrowserOffline, isNetworkError } from './network'
import type {
  OfflineState,
  OutboxItem,
  SyncResult,
} from './types'

let syncing = false
let state: OfflineState = {
  online: typeof navigator === 'undefined' ? true : navigator.onLine,
  pending: 0,
  failed: 0,
  syncing: false,
  lastError: null,
}

const listeners = new Set<(next: OfflineState) => void>()

function publish(next: Partial<OfflineState>): void {
  state = { ...state, ...next }
  for (const listener of listeners) listener(state)
}

export function getOfflineState(): OfflineState {
  return state
}

export function subscribeOfflineState(
  listener: (next: OfflineState) => void,
): () => void {
  listeners.add(listener)
  listener(state)
  return () => listeners.delete(listener)
}

export async function refreshOfflineState(shopId: string): Promise<void> {
  const snapshot = await getOutboxSnapshot(shopId)
  publish({
    pending: snapshot.pending,
    failed: snapshot.failed,
    lastError: snapshot.lastError,
  })
}

export function setNetworkReachable(reachable: boolean): void {
  publish({ online: reachable && !isBrowserOffline() })
}

function errorText(error: unknown): string {
  if (error && typeof error === 'object' && 'message' in error) {
    return String(error.message)
  }
  if (error instanceof Error) return error.message
  return 'Error de sincronización.'
}

async function applyClientCreate(item: OutboxItem & { type: 'client.create' }): Promise<void> {
  const payload = item.payload
  const { error } = await supabase.from('clients').insert({
    id: payload.id,
    shop_id: item.shopId,
    full_name: payload.full_name,
    phone: payload.phone,
    technical_notes: payload.technical_notes,
  })

  if (!error) return
  if (error.code !== '23505') throw error

  // Reintento de un alta que sí llegó al servidor.
  const byId = await supabase.from('clients').select('id').eq('id', payload.id).maybeSingle()
  if (byId.error) throw byId.error
  if (byId.data) return

  // Otro dispositivo ya había creado el mismo teléfono: reutilizamos esa ficha.
  const byPhone = await supabase
    .from('clients')
    .select('id')
    .eq('shop_id', item.shopId)
    .eq('phone', payload.phone)
    .maybeSingle()
  if (byPhone.error) throw byPhone.error
  if (!byPhone.data) throw error

  await remapClientInOutbox(item.shopId, payload.id, byPhone.data.id)
}

async function applyClientUpdate(item: OutboxItem & { type: 'client.update' }): Promise<void> {
  const { error } = await supabase
    .from('clients')
    .update(item.payload.patch)
    .eq('id', item.payload.id)
    .eq('shop_id', item.shopId)
  if (error) throw error
}

async function applyAppointmentCreate(
  item: OutboxItem & { type: 'appointment.create' },
): Promise<void> {
  const payload = item.payload
  const { error } = await supabase.from('appointments').insert({
    id: payload.id,
    shop_id: item.shopId,
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
    reminder_sent: payload.reminder_sent,
  })

  if (!error) return
  if (error.code === '23P01') {
    throw new Error('El horario se ocupó mientras estabas sin conexión. El turno no se sincronizó.')
  }
  if (error.code === '23505') {
    const existing = await supabase
      .from('appointments')
      .select('id')
      .eq('id', payload.id)
      .maybeSingle()
    if (!existing.error && existing.data) return
  }
  throw error
}

async function applyAppointmentStatus(
  item: OutboxItem & { type: 'appointment.status' },
): Promise<void> {
  const { error } = await supabase
    .from('appointments')
    .update({ status: item.payload.status })
    .eq('id', item.payload.id)
    .eq('shop_id', item.shopId)
  if (error?.code === '23P01') {
    throw new Error('No se pudo reabrir el turno: otro turno activo ocupa el horario.')
  }
  if (error) throw error
}

async function applyAppointmentReminder(
  item: OutboxItem & { type: 'appointment.reminder' },
): Promise<void> {
  const { error } = await supabase
    .from('appointments')
    .update({ reminder_sent: true })
    .eq('id', item.payload.id)
    .eq('shop_id', item.shopId)
  if (error) throw error
}

async function applyCashIncome(item: OutboxItem & { type: 'cash.income' }): Promise<void> {
  const payload = item.payload
  const { error } = await supabase.from('cash_movements').insert({
    id: payload.id,
    shop_id: item.shopId,
    appointment_id: payload.appointment_id,
    staff_id: payload.staff_id,
    item_id: payload.item_id,
    movement_type: 'income',
    description: payload.description,
    payment_method: payload.payment_method,
    gross_amount: payload.gross_amount,
    discount_amount: payload.discount_amount,
    supply_deduction: payload.supply_deduction,
    movement_date: payload.movement_date,
  })
  if (error?.code === '23505') return
  if (error) throw error
}

async function applyCashOutflow(item: OutboxItem & { type: 'cash.outflow' }): Promise<void> {
  const payload = item.payload
  const { error } = await supabase.from('cash_movements').insert({
    id: payload.id,
    shop_id: item.shopId,
    staff_id: payload.staff_id,
    movement_type: payload.movement_type,
    description: payload.description,
    payment_method: payload.payment_method,
    gross_amount: payload.gross_amount,
    movement_date: payload.movement_date,
  })
  if (error?.code === '23505') return
  if (error) throw error
}

async function applyItem(item: OutboxItem): Promise<void> {
  switch (item.type) {
    case 'client.create':
      return applyClientCreate(item)
    case 'client.update':
      return applyClientUpdate(item)
    case 'appointment.create':
      return applyAppointmentCreate(item)
    case 'appointment.status':
      return applyAppointmentStatus(item)
    case 'appointment.reminder':
      return applyAppointmentReminder(item)
    case 'cash.income':
      return applyCashIncome(item)
    case 'cash.outflow':
      return applyCashOutflow(item)
  }
}

export async function syncOutbox(
  shopId: string,
  options: { retryFailed?: boolean } = {},
): Promise<SyncResult> {
  if (syncing) return { synced: 0, failed: 0, stoppedOffline: false }
  if (isBrowserOffline()) {
    await refreshOfflineState(shopId)
    return { synced: 0, failed: 0, stoppedOffline: true }
  }

  syncing = true
  publish({ syncing: true, online: true, lastError: null })

  let synced = 0
  let failed = 0
  let stoppedOffline = false

  try {
    if (options.retryFailed) await retryFailedOutbox(shopId)
    const items = await getOutbox(shopId)

    for (const item of items) {
      if (item.status === 'failed') continue
      const current = await getOutboxItem(item.id)
      if (!current) continue
      try {
        await applyItem(current)
        await deleteOutbox(current.id)
        synced += 1
      } catch (error) {
        if (isNetworkError(error)) {
          stoppedOffline = true
          break
        }
        failed += 1
        await updateOutbox({
          ...current,
          status: 'failed',
          attempts: current.attempts + 1,
          lastError: errorText(error),
        })
      }
    }
  } finally {
    syncing = false
    const snapshot = await getOutboxSnapshot(shopId)
    publish({
      syncing: false,
      online: stoppedOffline ? false : !isBrowserOffline(),
      pending: snapshot.pending,
      failed: snapshot.failed,
      lastError: snapshot.lastError,
    })
    if (synced > 0) emitSyncComplete()
    emitOutboxChanged()
  }

  return { synced, failed, stoppedOffline }
}

export async function retryFailedAndSync(shopId: string): Promise<SyncResult> {
  await retryFailedOutbox(shopId)
  emitOutboxChanged()
  return syncOutbox(shopId)
}

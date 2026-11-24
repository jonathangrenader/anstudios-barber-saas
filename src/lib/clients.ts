import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'
import { cachedQuery } from './offline/cache'
import { addOutbox } from './offline/db'
import { emitOutboxChanged } from './offline/events'
import { cacheKeys } from './offline/keys'
import { isBrowserOffline, isNetworkError, newLocalId } from './offline/network'
import { overlayClients } from './offline/pending'
import type { Client, ClientInput } from '../types/client'
import type { ClientVisit } from '../types/appointment'
import type { MutationResult } from './offline/types'

/** El teléfono es la clave natural del cliente: se guarda solo con dígitos. */
export function normalizePhone(value: string): string {
  return value.replace(/\D/g, '')
}

export async function listClients(shopId: string): Promise<Client[]> {
  const rows = await cachedQuery(
    cacheKeys.clients(shopId),
    async () => {
      const { data, error } = await supabase
        .from('clients')
        .select('*')
        .eq('shop_id', shopId)
        .order('last_visit_at', { ascending: false, nullsFirst: false })
        .order('full_name')

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar los clientes.'))
      return (data ?? []) as Client[]
    },
    'Sin conexión y sin clientes guardados. Conectate una vez para poder consultarlos offline.',
  )

  return overlayClients(shopId, rows)
}

export async function createClient(shopId: string, input: ClientInput): Promise<Client> {
  const id = newLocalId()
  const payload = {
    id,
    shop_id: shopId,
    full_name: input.full_name.trim(),
    phone: normalizePhone(input.phone),
    technical_notes: input.technical_notes?.trim() || null,
  }

  if (!isBrowserOffline()) {
    try {
      const { data, error } = await supabase
        .from('clients')
        .insert(payload)
        .select('*')
        .single()

      if (error?.code === '23505') {
        throw new Error('Ya existe un cliente con ese teléfono en este local.')
      }
      if (error) throw new Error(dbErrorMessage(error, 'No pudimos crear el cliente.'))
      return data as Client
    } catch (error) {
      if (!isNetworkError(error)) throw error
    }
  }

  const client: Client = {
    ...payload,
    last_visit_at: null,
    total_visits: 0,
    created_at: new Date().toISOString(),
    sync_status: 'pending',
  }

  await addOutbox({
    id: newLocalId(),
    shopId,
    createdAt: new Date().toISOString(),
    attempts: 0,
    status: 'pending',
    lastError: null,
    type: 'client.create',
    payload: client,
  })
  emitOutboxChanged()
  return client
}

export async function updateClient(
  id: string,
  shopId: string,
  patch: Partial<ClientInput>,
): Promise<MutationResult> {
  const payload = {
    ...patch,
    ...(patch.full_name !== undefined ? { full_name: patch.full_name.trim() } : {}),
    ...(patch.phone !== undefined ? { phone: normalizePhone(patch.phone) } : {}),
    ...(patch.technical_notes !== undefined
      ? { technical_notes: patch.technical_notes?.trim() || null }
      : {}),
  }

  if (!isBrowserOffline()) {
    try {
      const { error } = await supabase.from('clients').update(payload).eq('id', id)

      if (error?.code === '23505') {
        throw new Error('Ya existe un cliente con ese teléfono en este local.')
      }
      if (error) throw new Error(dbErrorMessage(error, 'No pudimos actualizar el cliente.'))
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
    type: 'client.update',
    payload: { id, patch: payload },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

export async function findClientByPhone(shopId: string, phone: string): Promise<Client | null> {
  const { data, error } = await supabase
    .from('clients')
    .select('*')
    .eq('shop_id', shopId)
    .eq('phone', normalizePhone(phone))
    .maybeSingle()

  if (error) throw new Error(dbErrorMessage(error, 'No pudimos buscar el cliente.'))
  return (data as Client | null) ?? null
}

export async function listClientVisits(clientId: string, limit = 10): Promise<ClientVisit[]> {
  const { data, error } = await supabase
    .from('appointments')
    .select(
      'id, starts_at, ends_at, status, notes, service:catalog_items(name), staff:staff(name, color_hex)',
    )
    .eq('client_id', clientId)
    .order('starts_at', { ascending: false })
    .limit(limit)

  if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar el historial.'))
  return (data ?? []) as unknown as ClientVisit[]
}

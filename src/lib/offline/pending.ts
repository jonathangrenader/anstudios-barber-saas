import { cacheGet, getOutbox } from './db'
import { cacheKeys } from './keys'
import type { OutboxItem, OutboxStatus } from './types'
import type { AppointmentView } from '../../types/appointment'
import type { CashMovementView } from '../../types/cash'
import type { CatalogItem } from '../../types/catalog'
import type { Client } from '../../types/client'
import type { StaffMember } from '../../types/staff'

function syncStatus(item: OutboxItem): OutboxStatus {
  return item.status
}

function round2(value: number): number {
  return Math.round(value * 100) / 100
}

export async function overlayAppointments(
  shopId: string,
  rows: AppointmentView[],
  startIso: string,
  endIso: string,
): Promise<AppointmentView[]> {
  const outbox = await getOutbox(shopId)
  const appointmentItems = outbox.filter(
    (item) =>
      item.type === 'appointment.create' ||
      item.type === 'appointment.status' ||
      item.type === 'appointment.reminder',
  )
  if (appointmentItems.length === 0) return rows

  const [staff, catalog] = await Promise.all([
    cacheGet<StaffMember[]>(cacheKeys.staff(shopId)),
    cacheGet<CatalogItem[]>(cacheKeys.catalog(shopId)),
  ])
  const staffById = new Map((staff ?? []).map((member) => [member.id, member]))
  const serviceById = new Map((catalog ?? []).map((item) => [item.id, item]))
  const byId = new Map(rows.map((row) => [row.id, row]))

  for (const item of appointmentItems) {
    if (item.type === 'appointment.create') {
      const payload = item.payload
      if (payload.starts_at < startIso || payload.starts_at >= endIso) continue
      const member = staffById.get(payload.staff_id)
      const service = payload.service_id ? serviceById.get(payload.service_id) : undefined
      byId.set(payload.id, {
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
        reminder_sent: payload.reminder_sent,
        notes: payload.notes,
        created_at: payload.created_at,
        service: service ? { name: service.name } : null,
        staff: member ? { name: member.name, color_hex: member.color_hex } : null,
        sync_status: syncStatus(item),
      })
    } else if (item.type === 'appointment.status') {
      const current = byId.get(item.payload.id)
      if (current) {
        byId.set(current.id, {
          ...current,
          status: item.payload.status,
          sync_status: syncStatus(item),
        })
      }
    } else {
      const current = byId.get(item.payload.id)
      if (current) {
        byId.set(current.id, {
          ...current,
          reminder_sent: true,
          sync_status: syncStatus(item),
        })
      }
    }
  }

  return [...byId.values()].sort((a, b) => a.starts_at.localeCompare(b.starts_at))
}

export async function overlayCashMovements(
  shopId: string,
  rows: CashMovementView[],
  startIso: string,
  endIso: string,
): Promise<CashMovementView[]> {
  const outbox = await getOutbox(shopId)
  const movementItems = outbox.filter(
    (item) => item.type === 'cash.income' || item.type === 'cash.outflow',
  )
  if (movementItems.length === 0) return rows

  const [staff, catalog] = await Promise.all([
    cacheGet<StaffMember[]>(cacheKeys.staff(shopId)),
    cacheGet<CatalogItem[]>(cacheKeys.catalog(shopId)),
  ])
  const staffById = new Map((staff ?? []).map((member) => [member.id, member]))
  const itemById = new Map((catalog ?? []).map((item) => [item.id, item]))
  const byId = new Map(rows.map((row) => [row.id, row]))

  for (const item of movementItems) {
    if (item.type === 'cash.outflow') {
      const payload = item.payload
      if (payload.movement_date < startIso || payload.movement_date >= endIso) continue
      const member = payload.staff_id ? staffById.get(payload.staff_id) : undefined
      byId.set(payload.id, {
        id: payload.id,
        shop_id: item.shopId,
        appointment_id: null,
        staff_id: payload.staff_id,
        item_id: null,
        movement_type: payload.movement_type,
        description: payload.description,
        payment_method: payload.payment_method,
        gross_amount: payload.gross_amount,
        discount_amount: 0,
        supply_deduction: 0,
        net_base_amount: 0,
        commission_pct_applied: 0,
        staff_commission_amount: 0,
        shop_net_amount: 0,
        is_settled: false,
        movement_date: payload.movement_date,
        created_at: payload.created_at,
        staff: member ? { name: member.name, color_hex: member.color_hex } : null,
        item: null,
        appointment: null,
        sync_status: syncStatus(item),
      })
      continue
    }

    const payload = item.payload
    if (payload.movement_date < startIso || payload.movement_date >= endIso) continue

    const member = staffById.get(payload.staff_id)
    const catalogItem = payload.item_id ? itemById.get(payload.item_id) : undefined
    const netBase = round2(
      Math.max(0, payload.gross_amount - payload.discount_amount - payload.supply_deduction),
    )
    const pct = member
      ? catalogItem?.type === 'product'
        ? member.product_commission_pct
        : member.commission_pct
      : 0
    const commission = round2((netBase * pct) / 100)

    byId.set(payload.id, {
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
      net_base_amount: netBase,
      commission_pct_applied: pct,
      staff_commission_amount: commission,
      shop_net_amount: round2(netBase - commission),
      is_settled: false,
      movement_date: payload.movement_date,
      created_at: payload.created_at,
      staff: member ? { name: member.name, color_hex: member.color_hex } : null,
      item: catalogItem ? { name: catalogItem.name, type: catalogItem.type } : null,
      appointment: null,
      sync_status: syncStatus(item),
    })
  }

  return [...byId.values()].sort((a, b) => {
    const byDate = b.movement_date.localeCompare(a.movement_date)
    return byDate !== 0 ? byDate : b.created_at.localeCompare(a.created_at)
  })
}

export async function overlayClients(shopId: string, rows: Client[]): Promise<Client[]> {
  const outbox = await getOutbox(shopId)
  const clientItems = outbox.filter(
    (item) => item.type === 'client.create' || item.type === 'client.update',
  )
  if (clientItems.length === 0) return rows

  const byId = new Map(rows.map((row) => [row.id, row]))

  for (const item of clientItems) {
    if (item.type === 'client.create') {
      byId.set(item.payload.id, {
        ...item.payload,
        sync_status: syncStatus(item),
      })
      continue
    }

    const current = byId.get(item.payload.id)
    if (!current) continue
    const patch = item.payload.patch
    byId.set(current.id, {
      ...current,
      ...(patch.full_name !== undefined ? { full_name: patch.full_name } : {}),
      ...(patch.phone !== undefined ? { phone: patch.phone } : {}),
      ...(patch.technical_notes !== undefined
        ? { technical_notes: patch.technical_notes }
        : {}),
      sync_status: syncStatus(item),
    })
  }

  return [...byId.values()].sort((a, b) => {
    if (a.last_visit_at === b.last_visit_at) {
      return a.full_name.localeCompare(b.full_name, 'es')
    }
    if (a.last_visit_at === null) return 1
    if (b.last_visit_at === null) return -1
    return b.last_visit_at.localeCompare(a.last_visit_at)
  })
}

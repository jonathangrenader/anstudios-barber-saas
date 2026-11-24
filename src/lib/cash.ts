import { supabase } from './supabase'
import { shopDateKey, zonedTimeToUtc } from './datetime'
import { cachedQuery } from './offline/cache'
import { addOutbox, getOutbox } from './offline/db'
import { emitOutboxChanged } from './offline/events'
import { cacheKeys } from './offline/keys'
import { isBrowserOffline, isNetworkError, newLocalId } from './offline/network'
import { overlayCashMovements } from './offline/pending'
import type { MutationResult } from './offline/types'
import type {
  CashIncomeInput,
  CashMovement,
  CashMovementView,
  CashOutflowInput,
} from '../types/cash'

type ErrorLike = { code?: string; message: string }

type NumericFields = Pick<
  CashMovement,
  | 'gross_amount'
  | 'discount_amount'
  | 'supply_deduction'
  | 'net_base_amount'
  | 'staff_commission_amount'
  | 'shop_net_amount'
>

type CashRow = Omit<CashMovementView, keyof NumericFields | 'commission_pct_applied'> &
  Record<keyof NumericFields, number | string> & {
    commission_pct_applied: number | string | null
  }

function round2(value: number): number {
  return Math.round(value * 100) / 100
}

function cashErrorMessage(error: ErrorLike, fallback: string): Error {
  if (error.code === '23514') {
    return new Error(error.message || 'Los importes no respetan las reglas de la caja.')
  }
  if (error.code === '23503') {
    return new Error('El turno o el profesional ya no están disponibles.')
  }
  if (error.code === '42501') {
    return new Error('No tenés permiso para registrar este movimiento.')
  }
  if (error.code === '22P02') {
    return new Error('Alguno de los importes no es válido.')
  }
  return new Error(error.message || fallback)
}

function toNumber(value: number | string): number {
  return Number(value)
}

export function movementDateForDay(dateKey: string, timezone: string): string {
  if (dateKey === shopDateKey(new Date(), timezone)) {
    return new Date().toISOString()
  }
  return zonedTimeToUtc(dateKey, '12:00', timezone).toISOString()
}

export async function listCashMovements(
  shopId: string,
  startIso: string,
  endIso: string,
): Promise<CashMovementView[]> {
  const rows = await cachedQuery(
    cacheKeys.cash(shopId, startIso, endIso),
    async () => {
      const { data, error } = await supabase
        .from('cash_movements')
        .select(
          '*, staff:staff(name, color_hex), item:catalog_items(name, type), appointment:appointments(client_name_snapshot, starts_at)',
        )
        .eq('shop_id', shopId)
        .gte('movement_date', startIso)
        .lt('movement_date', endIso)
        .order('movement_date', { ascending: false })
        .order('created_at', { ascending: false })
        .limit(300)

      if (error) throw new Error(error.message || 'No pudimos cargar la caja.')

      return ((data ?? []) as unknown as CashRow[]).map((row) => ({
        ...row,
        gross_amount: toNumber(row.gross_amount),
        discount_amount: toNumber(row.discount_amount),
        supply_deduction: toNumber(row.supply_deduction),
        net_base_amount: toNumber(row.net_base_amount),
        staff_commission_amount: toNumber(row.staff_commission_amount),
        shop_net_amount: toNumber(row.shop_net_amount),
        commission_pct_applied:
          row.commission_pct_applied === null
            ? null
            : toNumber(row.commission_pct_applied),
      }))
    },
    'Sin conexión y sin caja guardada para este día. Conectate una vez para poder consultarla offline.',
  )

  return overlayCashMovements(shopId, rows, startIso, endIso)
}

export async function createCashIncome(
  shopId: string,
  input: CashIncomeInput,
): Promise<MutationResult> {
  if (!input.staff_id) throw new Error('Elegí el profesional que realizó el trabajo.')
  if (input.discount_amount + input.supply_deduction > input.gross_amount) {
    throw new Error('El descuento más los insumos no pueden superar el importe bruto.')
  }

  const id = newLocalId()
  const createdAt = new Date().toISOString()
  const queued = await getOutbox(shopId)
  const pendingAppointment =
    input.appointment_id !== null &&
    queued.some(
      (item) =>
        item.type === 'appointment.create' && item.payload.id === input.appointment_id,
    )

  if (!isBrowserOffline() && !pendingAppointment) {
    try {
      if (input.appointment_id) {
        const { count, error } = await supabase
          .from('cash_movements')
          .select('id', { count: 'exact', head: true })
          .eq('shop_id', shopId)
          .eq('appointment_id', input.appointment_id)
          .eq('movement_type', 'income')

        if (error) throw cashErrorMessage(error, 'No pudimos verificar el cobro del turno.')
        if ((count ?? 0) > 0) throw new Error('Ese turno ya tiene un cobro registrado.')
      }

      const { error } = await supabase.from('cash_movements').insert({
        id,
        shop_id: shopId,
        appointment_id: input.appointment_id,
        staff_id: input.staff_id,
        item_id: input.item_id,
        movement_type: 'income',
        description: input.description.trim(),
        payment_method: input.payment_method,
        gross_amount: round2(input.gross_amount),
        discount_amount: round2(input.discount_amount),
        supply_deduction: round2(input.supply_deduction),
        movement_date: input.movement_date,
      })

      if (error) throw cashErrorMessage(error, 'No pudimos registrar el cobro.')
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
    type: 'cash.income',
    payload: {
      ...input,
      id,
      shop_id: shopId,
      created_at: createdAt,
      description: input.description.trim(),
      gross_amount: round2(input.gross_amount),
      discount_amount: round2(input.discount_amount),
      supply_deduction: round2(input.supply_deduction),
    },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

export async function createCashOutflow(
  shopId: string,
  input: CashOutflowInput,
): Promise<MutationResult> {
  if (input.movement_type === 'staff_advance' && !input.staff_id) {
    throw new Error('Elegí a qué profesional se le entrega el adelanto.')
  }
  if (input.gross_amount <= 0) {
    throw new Error('El importe debe ser mayor a cero.')
  }

  const id = newLocalId()
  const createdAt = new Date().toISOString()
  const amount = round2(input.gross_amount)

  if (!isBrowserOffline()) {
    try {
      const { error } = await supabase.from('cash_movements').insert({
        id,
        shop_id: shopId,
        staff_id: input.movement_type === 'staff_advance' ? input.staff_id : null,
        movement_type: input.movement_type,
        description: input.description.trim(),
        payment_method: input.payment_method,
        gross_amount: amount,
        movement_date: input.movement_date,
      })

      if (error) throw cashErrorMessage(error, 'No pudimos registrar el movimiento.')
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
    type: 'cash.outflow',
    payload: {
      ...input,
      id,
      shop_id: shopId,
      created_at: createdAt,
      staff_id: input.movement_type === 'staff_advance' ? input.staff_id : null,
      description: input.description.trim(),
      gross_amount: amount,
    },
  })
  emitOutboxChanged()
  return { queued: true, id }
}

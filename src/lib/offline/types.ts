import type {
  AppointmentStatus,
  NewAppointmentInput,
} from '../../types/appointment'
import type { CashIncomeInput, CashOutflowInput } from '../../types/cash'
import type { Client, ClientInput } from '../../types/client'

export type OutboxStatus = 'pending' | 'failed'

type OutboxBase = {
  id: string
  shopId: string
  createdAt: string
  attempts: number
  status: OutboxStatus
  lastError: string | null
}

export type ClientCreatePayload = Client
export type ClientUpdatePayload = { id: string; patch: Partial<ClientInput> }
export type AppointmentCreatePayload = NewAppointmentInput & {
  id: string
  shop_id: string
  created_at: string
  reminder_sent: boolean
}
export type AppointmentStatusPayload = {
  id: string
  status: AppointmentStatus
}
export type AppointmentReminderPayload = { id: string }
export type CashIncomePayload = CashIncomeInput & {
  id: string
  shop_id: string
  created_at: string
}
export type CashOutflowPayload = CashOutflowInput & {
  id: string
  shop_id: string
  created_at: string
}

export type OutboxItem =
  | (OutboxBase & { type: 'client.create'; payload: ClientCreatePayload })
  | (OutboxBase & { type: 'client.update'; payload: ClientUpdatePayload })
  | (OutboxBase & { type: 'appointment.create'; payload: AppointmentCreatePayload })
  | (OutboxBase & { type: 'appointment.status'; payload: AppointmentStatusPayload })
  | (OutboxBase & { type: 'appointment.reminder'; payload: AppointmentReminderPayload })
  | (OutboxBase & { type: 'cash.income'; payload: CashIncomePayload })
  | (OutboxBase & { type: 'cash.outflow'; payload: CashOutflowPayload })

export type OutboxType = OutboxItem['type']

export type MutationResult = {
  queued: boolean
  id: string
}

export type OfflineState = {
  online: boolean
  pending: number
  failed: number
  syncing: boolean
  lastError: string | null
}

export type SyncResult = {
  synced: number
  failed: number
  stoppedOffline: boolean
}

import type { AppointmentStatus } from '../types/appointment'

export const STATUS_META: Record<
  AppointmentStatus,
  { label: string; className: string }
> = {
  pending: { label: 'Pendiente', className: 'bg-pending-soft text-pending' },
  confirmed: { label: 'Confirmado', className: 'bg-income-soft text-income' },
  in_progress: { label: 'En curso', className: 'bg-pending-soft text-pending' },
  completed: { label: 'Completado', className: 'bg-surface-alt text-muted' },
  cancelled: { label: 'Cancelado', className: 'bg-expense-soft text-expense' },
  no_show: { label: 'Ausente', className: 'bg-expense-soft text-expense' },
}

export type StatusActionVariant = 'primary' | 'secondary' | 'danger'

export type StatusAction = {
  status: AppointmentStatus
  label: string
  variant: StatusActionVariant
}

/** Transiciones permitidas desde la ficha del turno (el dueño escribe bajo RLS). */
export const STATUS_ACTIONS: Record<AppointmentStatus, StatusAction[]> = {
  pending: [
    { status: 'confirmed', label: 'Confirmar turno', variant: 'primary' },
    { status: 'cancelled', label: 'Cancelar turno', variant: 'danger' },
  ],
  confirmed: [
    { status: 'in_progress', label: 'Iniciar atención', variant: 'primary' },
    { status: 'completed', label: 'Completar', variant: 'secondary' },
    { status: 'no_show', label: 'No vino', variant: 'secondary' },
    { status: 'cancelled', label: 'Cancelar turno', variant: 'danger' },
  ],
  in_progress: [
    { status: 'completed', label: 'Completar', variant: 'primary' },
    { status: 'cancelled', label: 'Cancelar turno', variant: 'danger' },
  ],
  completed: [],
  cancelled: [{ status: 'confirmed', label: 'Reabrir turno', variant: 'secondary' }],
  no_show: [{ status: 'confirmed', label: 'Reabrir turno', variant: 'secondary' }],
}

export function isRemindable(status: AppointmentStatus): boolean {
  return status === 'pending' || status === 'confirmed'
}

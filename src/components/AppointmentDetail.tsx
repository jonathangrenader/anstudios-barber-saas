import { useEffect, useState } from 'react'
import { Check, MessageCircle, Phone } from 'lucide-react'
import {
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import { listStaff } from '../lib/staff'
import { markReminderSent, reassignAppointment, rescheduleAppointment, updateAppointmentStatus } from '../lib/appointments'
import {
  isRemindable,
  STATUS_ACTIONS,
  STATUS_META,
  type StatusAction,
} from '../lib/status'
import { buildReminderUrl, toWhatsAppPhone } from '../lib/whatsapp'
import type {
  AppointmentStatus,
  AppointmentView,
} from '../types/appointment'
import type { Shop } from '../types/shop'
import type { StaffMember } from '../types/staff'
import { Button, FieldError } from './ui/controls'

const SOURCE_LABEL = {
  admin: 'Cargado por el local',
  public_link: 'Reserva online',
  walk_in: 'Al paso',
} as const

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

export function AppointmentDetail({
  shop,
  appointment,
  onUpdated,
}: {
  shop: Shop
  appointment: AppointmentView
  onUpdated: (appointment: AppointmentView) => void
}) {
  const [pendingStatus, setPendingStatus] = useState<AppointmentStatus | null>(null)
  const [statusError, setStatusError] = useState<string | null>(null)
  const [statusNotice, setStatusNotice] = useState<string | null>(null)
  const [confirmCancel, setConfirmCancel] = useState(false)
  const [reminderBusy, setReminderBusy] = useState(false)
  const [reminderError, setReminderError] = useState<string | null>(null)

  const [staffList, setStaffList] = useState<StaffMember[]>([])
  const [manageStaffId, setManageStaffId] = useState(appointment.staff_id ?? '')
  const [manageTime, setManageTime] = useState('')
  const [manageBusy, setManageBusy] = useState(false)
  const [manageError, setManageError] = useState<string | null>(null)
  const [manageNotice, setManageNotice] = useState<string | null>(null)

  useEffect(() => {
    void listStaff(appointment.shop_id).then(setStaffList).catch(() => setStaffList([]))
  }, [appointment.shop_id])

  const meta = STATUS_META[appointment.status]
  const actions = STATUS_ACTIONS[appointment.status]
  const remindable = isRemindable(appointment.status)
  const dateLabel = dateKeyLongLabel(
    shopDateKey(new Date(appointment.starts_at), shop.timezone),
  )
  const phoneHref = `tel:${appointment.client_phone_snapshot.replace(/[^\d+]/g, '')}`

  async function changeStatus(status: AppointmentStatus) {
    if (pendingStatus) return
    setPendingStatus(status)
    setStatusError(null)
    setStatusNotice(null)

    try {
      const result = await updateAppointmentStatus(
        appointment.id,
        appointment.shop_id,
        status,
      )
      onUpdated({
        ...appointment,
        status,
        ...(result.queued ? { sync_status: 'pending' as const } : {}),
      })
      setStatusNotice(
        result.queued
          ? 'Estado guardado sin conexión. Se sincronizará al reconectar.'
          : null,
      )
      setConfirmCancel(false)
    } catch (error) {
      setStatusError(errorMessage(error, 'No pudimos actualizar el turno.'))
    } finally {
      setPendingStatus(null)
    }
  }

  function runAction(action: StatusAction) {
    if (action.status === 'cancelled') {
      setConfirmCancel(true)
      return
    }
    void changeStatus(action.status)
  }

  function sendReminder() {
    const url = buildReminderUrl(shop, appointment)
    if (!url) {
      setReminderError(
        'El teléfono guardado no permite armar el link de WhatsApp. Corregilo desde Clientes.',
      )
      return
    }

    setReminderError(null)
    window.open(url, '_blank', 'noopener,noreferrer')
    setReminderBusy(true)

    void markReminderSent(appointment.id, appointment.shop_id)
      .then((result) =>
        onUpdated({
          ...appointment,
          reminder_sent: true,
          ...(result.queued ? { sync_status: 'pending' as const } : {}),
        }),
      )
      .catch((error: unknown) => {
        setReminderError(
          `Se abrió WhatsApp, pero no pudimos guardar la marca: ${errorMessage(
            error,
            'error desconocido.',
          )}`,
        )
      })
      .finally(() => setReminderBusy(false))
  }

  async function handleReassign() {
    if (!manageStaffId || manageStaffId === appointment.staff_id) return
    setManageBusy(true)
    setManageError(null)
    setManageNotice(null)
    try {
      await reassignAppointment(appointment.id, manageStaffId)
      const staff = staffList.find((item) => item.id === manageStaffId)
      onUpdated({ ...appointment, staff_id: manageStaffId, staff: staff ? { name: staff.name, color_hex: staff.color_hex } : appointment.staff })
      setManageNotice('Turno reasignado.')
    } catch (err) {
      setManageError(err instanceof Error ? err.message : 'No pudimos reasignar el turno.')
    } finally {
      setManageBusy(false)
    }
  }

  async function handleReschedule() {
    if (!manageTime) return
    setManageBusy(true)
    setManageError(null)
    setManageNotice(null)
    try {
      const iso = `${manageTime}:00-03:00`
      const result = await rescheduleAppointment(appointment.id, iso)
      onUpdated({ ...appointment, starts_at: result.starts_at, ends_at: result.ends_at })
      setManageNotice('Turno reprogramado.')
    } catch (err) {
      setManageError(err instanceof Error ? err.message : 'No pudimos reprogramar el turno.')
    } finally {
      setManageBusy(false)
    }
  }

  function notifyClient(message: string) {
    const phone = toWhatsAppPhone(appointment.client_phone_snapshot)
    if (!phone) {
      setManageError('El teléfono del cliente no permite armar el link de WhatsApp.')
      return
    }
    window.open(`https://wa.me/${phone}?text=${encodeURIComponent(message)}`, '_blank', 'noopener,noreferrer')
  }

  return (
    <div className="space-y-4">
      <div className="rounded-xl border border-base bg-surface-alt/60 p-3">
        <div className="flex items-start justify-between gap-2">
          <p className="numeric text-xl font-bold">
            {zonedTime(appointment.starts_at, shop.timezone)}–
            {zonedTime(appointment.ends_at, shop.timezone)}
          </p>
          <span
            className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${meta.className}`}
          >
            {meta.label}
          </span>
        </div>
        <p className="mt-0.5 text-sm font-medium">{dateLabel}</p>
      </div>

      <dl className="space-y-2 text-sm">
        <div className="flex items-baseline justify-between gap-3">
          <dt className="text-xs text-muted">Cliente</dt>
          <dd className="text-right font-semibold">{appointment.client_name_snapshot}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-3">
          <dt className="text-xs text-muted">Teléfono</dt>
          <dd className="text-right">
            <a
              href={phoneHref}
              className="numeric inline-flex min-h-[44px] items-center gap-1.5 font-medium underline decoration-base underline-offset-4 hover:decoration-strong"
            >
              <Phone size={14} aria-hidden="true" />
              {appointment.client_phone_snapshot}
            </a>
          </dd>
        </div>
        <div className="flex items-baseline justify-between gap-3">
          <dt className="text-xs text-muted">Servicio</dt>
          <dd className="text-right font-medium">{appointment.service?.name ?? 'Sin servicio'}</dd>
        </div>
        <div className="flex items-baseline justify-between gap-3">
          <dt className="text-xs text-muted">Profesional</dt>
          <dd className="flex items-center justify-end gap-1.5 text-right font-medium">
            {appointment.staff && (
              <span
                aria-hidden="true"
                className="size-2 rounded-full border border-strong/20"
                style={{ backgroundColor: appointment.staff.color_hex }}
              />
            )}
            {appointment.staff?.name ?? 'Sin asignar'}
          </dd>
        </div>
        <div className="flex items-baseline justify-between gap-3">
          <dt className="text-xs text-muted">Origen</dt>
          <dd className="text-right font-medium">{SOURCE_LABEL[appointment.source]}</dd>
        </div>
      </dl>

      {appointment.notes && (
        <div className="rounded-xl border border-base bg-surface p-3">
          <p className="text-xs font-semibold text-muted">Notas del turno</p>
          <p className="mt-1 whitespace-pre-wrap text-sm">{appointment.notes}</p>
        </div>
      )}

      {remindable && (
        <div className="rounded-xl border border-base bg-surface p-3">
          <p className="text-sm font-semibold">Recordatorio por WhatsApp</p>
          <p className="mt-0.5 text-xs text-muted">
            Abre WhatsApp con el mensaje ya escrito para este turno.
          </p>
          <div className="mt-3">
            <Button
              type="button"
              variant={appointment.reminder_sent ? 'secondary' : 'primary'}
              loading={reminderBusy}
              onClick={sendReminder}
            >
              {!reminderBusy && <MessageCircle size={16} aria-hidden="true" />}
              {appointment.reminder_sent ? 'Reenviar recordatorio' : 'Recordar por WhatsApp'}
            </Button>
          </div>
          {appointment.reminder_sent && (
            <p className="mt-2 flex items-center gap-1.5 text-xs font-medium text-income">
              <Check size={14} aria-hidden="true" />
              Recordatorio abierto desde este local
            </p>
          )}
          <div className="mt-1.5">
            <FieldError>{reminderError}</FieldError>
          </div>
        </div>
      )}

      <div className="rounded-xl border border-base bg-surface p-3">
        <h3 className="text-sm font-semibold">Gestión del turno</h3>
        <p className="mt-0.5 text-xs text-muted">
          Reasigná el turno a otro profesional o reprogramalo. Avisá al cliente por
          WhatsApp.
        </p>

        <div className="mt-3 space-y-3">
          <div>
            <label className="text-xs font-medium text-muted">Profesional</label>
            <div className="mt-1.5 flex gap-2">
              <select
                value={manageStaffId}
                onChange={(event) => setManageStaffId(event.target.value)}
                className="min-h-[44px] flex-1 rounded-lg border border-base bg-surface px-3 text-sm"
              >
                {staffList.map((member) => (
                  <option key={member.id} value={member.id}>
                    {member.name}
                  </option>
                ))}
              </select>
              <Button
                type="button"
                variant="secondary"
                loading={manageBusy}
                disabled={manageBusy || !manageStaffId || manageStaffId === appointment.staff_id}
                onClick={() => void handleReassign()}
              >
                Reasignar
              </Button>
            </div>
          </div>

          <div>
            <label className="text-xs font-medium text-muted">Nuevo horario</label>
            <div className="mt-1.5 flex gap-2">
              <input
                type="datetime-local"
                value={manageTime}
                onChange={(event) => setManageTime(event.target.value)}
                className="min-h-[44px] flex-1 rounded-lg border border-base bg-surface px-3 text-sm"
              />
              <Button
                type="button"
                variant="secondary"
                loading={manageBusy}
                disabled={manageBusy || !manageTime}
                onClick={() => void handleReschedule()}
              >
                Reprogramar
              </Button>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-2">
            <Button
              type="button"
              variant="secondary"
              onClick={() =>
                notifyClient(
                  `Hola, te avisamos que tu turno en ${shop.name} fue reasignado a ${
                    staffList.find((s) => s.id === manageStaffId)?.name ?? 'otro profesional'
                  }. Si no podés, avisanos.`,
                )
              }
            >
              Avisar reasignación
            </Button>
            <Button
              type="button"
              variant="secondary"
              onClick={() =>
                notifyClient(
                  `Hola, tu turno en ${shop.name} cambió de horario. Nuevo horario: ${manageTime || zonedTime(appointment.starts_at, shop.timezone)}. Si no podés, avisanos.`,
                )
              }
            >
              Avisar cambio
            </Button>
          </div>

          {manageNotice && (
            <p className="rounded-lg border border-income/30 bg-income-soft px-3 py-2 text-xs font-medium text-income">
              {manageNotice}
            </p>
          )}
          <FieldError>{manageError}</FieldError>
        </div>
      </div>

      <div>
        <h3 className="text-sm font-semibold">Estado del turno</h3>
        <div className="mt-1">
          <FieldError>{statusError}</FieldError>
          {statusNotice && (
            <p className="rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending">
              {statusNotice}
            </p>
          )}
        </div>

        {actions.length === 0 && (
          <p className="mt-2 text-xs text-muted">
            Turno cerrado. Ya no admite cambios de estado.
          </p>
        )}

        {confirmCancel ? (
          <div className="mt-2 rounded-xl border border-base bg-expense-soft/40 p-3">
            <p className="text-sm font-semibold">¿Cancelar este turno?</p>
            <p className="mt-1 text-xs text-muted">
              El horario queda libre y no se cuenta como visita del cliente.
            </p>
            <div className="mt-3 grid grid-cols-2 gap-2">
              <Button
                type="button"
                variant="secondary"
                disabled={pendingStatus !== null}
                onClick={() => setConfirmCancel(false)}
              >
                Volver
              </Button>
              <Button
                type="button"
                variant="danger"
                loading={pendingStatus === 'cancelled'}
                onClick={() => void changeStatus('cancelled')}
              >
                Sí, cancelar
              </Button>
            </div>
          </div>
        ) : (
          actions.length > 0 && (
            <div className="mt-2 grid gap-2 sm:grid-cols-2">
              {actions.map((action) => (
                <Button
                  key={action.status}
                  type="button"
                  variant={action.variant}
                  loading={pendingStatus === action.status}
                  disabled={pendingStatus !== null && pendingStatus !== action.status}
                  onClick={() => runAction(action)}
                >
                  {action.label}
                </Button>
              ))}
            </div>
          )
        )}
      </div>
    </div>
  )
}

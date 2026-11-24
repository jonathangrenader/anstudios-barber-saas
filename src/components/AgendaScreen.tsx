import { useEffect, useState } from 'react'
import {
  ChevronLeft,
  ChevronRight,
  Loader2,
  MessageCircle,
  Phone,
  Plus,
  UserRound,
} from 'lucide-react'
import { useAgenda } from '../hooks/useAgenda'
import {
  listPendingAppointments,
  rejectAppointment,
  updateAppointmentStatus,
} from '../lib/appointments'
import { useCatalog } from '../hooks/useCatalog'
import { useStaff } from '../hooks/useStaff'
import {
  addDaysToDateKey,
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import { isRemindable, STATUS_META } from '../lib/status'
import type { AppointmentStatus, AppointmentView } from '../types/appointment'
import type { Shop } from '../types/shop'
import { markReminderSent } from '../lib/appointments'
import { buildReminderUrl } from '../lib/whatsapp'
import { AppointmentDetail } from './AppointmentDetail'
import { AppointmentForm } from './AppointmentForm'
import { Modal } from './ui/Modal'
import { Button } from './ui/controls'

const ACTIVE_STATUSES: AppointmentStatus[] = ['pending', 'confirmed', 'in_progress']

function durationLabel(minutes: number): string {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  if (hours === 0) return `${rest}m`
  return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`
}

export function AgendaScreen({
  shop,
  onOpenClients,
}: {
  shop: Shop
  onOpenClients: () => void
}) {
  const today = shopDateKey(new Date(), shop.timezone)
  const [dateKey, setDateKey] = useState(today)
  const [staffFilter, setStaffFilter] = useState<string>('all')
  const [formOpen, setFormOpen] = useState(false)
  const [selected, setSelected] = useState<AppointmentView | null>(null)
  const [reminderBusyId, setReminderBusyId] = useState<string | null>(null)
  const [reminderError, setReminderError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const [pendingAppointments, setPendingAppointments] = useState<AppointmentView[]>([])
  const [pendingError, setPendingError] = useState<string | null>(null)
  const [rejectingId, setRejectingId] = useState<string | null>(null)
  const [rejectReason, setRejectReason] = useState('')
  const [pendingBusyId, setPendingBusyId] = useState<string | null>(null)

  const { appointments, loading, error, reload } = useAgenda(shop.id, dateKey, shop.timezone)
  const { members } = useStaff(shop.id)
  const { items } = useCatalog(shop.id)

  const activeStaff = members.filter((member) => member.is_active)
  const activeServices = items.filter((item) => item.type === 'service' && item.is_active)
  const filtered =
    staffFilter === 'all'
      ? appointments
      : appointments.filter((appointment) => appointment.staff_id === staffFilter)

  const activeAppointments = filtered.filter((appointment) =>
    ACTIVE_STATUSES.includes(appointment.status),
  )
  const totalMinutes = activeAppointments.reduce(
    (total, appointment) =>
      total +
      Math.max(
        0,
        (new Date(appointment.ends_at).getTime() - new Date(appointment.starts_at).getTime()) /
          60_000,
      ),
    0,
  )

  function moveDay(days: number) {
    setDateKey((current) => addDaysToDateKey(current, days))
    setReminderError(null)
  }

  async function loadPending() {
    setPendingError(null)
    try {
      const rows = await listPendingAppointments(shop.id)
      setPendingAppointments(rows)
    } catch (err) {
      setPendingError(
        err instanceof Error ? err.message : 'No pudimos cargar los turnos pendientes.',
      )
    }
  }

  useEffect(() => {
    void loadPending()
  }, [shop.id])

  async function acceptPending(appointment: AppointmentView) {
    if (pendingBusyId) return
    setPendingBusyId(appointment.id)
    setPendingError(null)
    try {
      await updateAppointmentStatus(appointment.id, appointment.shop_id, 'confirmed')
      setPendingAppointments((current) => current.filter((item) => item.id !== appointment.id))
      setNotice('Turno aceptado.')
      void reload()
    } catch (err) {
      setPendingError(err instanceof Error ? err.message : 'No pudimos aceptar el turno.')
    } finally {
      setPendingBusyId(null)
    }
  }

  async function rejectPending(appointment: AppointmentView) {
    if (pendingBusyId) return
    setPendingBusyId(appointment.id)
    setPendingError(null)
    try {
      await rejectAppointment(appointment.id, appointment.shop_id, rejectReason)
      setPendingAppointments((current) => current.filter((item) => item.id !== appointment.id))
      setRejectingId(null)
      setRejectReason('')
      setNotice('Turno rechazado. El cliente verá el motivo en su turno.')
      void reload()
    } catch (err) {
      setPendingError(err instanceof Error ? err.message : 'No pudimos rechazar el turno.')
    } finally {
      setPendingBusyId(null)
    }
  }

  async function sendReminder(appointment: AppointmentView) {
    if (reminderBusyId) return

    const url = buildReminderUrl(shop, appointment)
    if (!url) {
      setReminderError(
        'Ese teléfono no permite armar el link de WhatsApp. Corregilo desde Clientes.',
      )
      return
    }

    setReminderError(null)
    window.open(url, '_blank', 'noopener,noreferrer')
    setReminderBusyId(appointment.id)

    try {
      await markReminderSent(appointment.id, appointment.shop_id)
      setSelected((current) =>
        current && current.id === appointment.id
          ? { ...current, reminder_sent: true }
          : current,
      )
      void reload()
    } catch (error) {
      setReminderError(
        error instanceof Error
          ? error.message
          : 'No pudimos marcar el recordatorio.',
      )
    } finally {
      setReminderBusyId(null)
    }
  }

  return (
    <section aria-labelledby="agenda-heading">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="agenda-heading" className="text-base font-bold">
            Agenda
          </h2>
          <p className="mt-0.5 text-xs text-muted">Turnos del día por profesional.</p>
        </div>
        <button
          type="button"
          onClick={() => setFormOpen(true)}
          className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-3 text-sm font-semibold text-white shadow-tactile"
        >
          <Plus size={16} aria-hidden="true" />
          Nuevo turno
        </button>
      </div>

      {notice && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending"
        >
          {notice}
        </p>
      )}

      {pendingAppointments.length > 0 && (
        <section className="mt-4 rounded-xl border border-pending/40 bg-pending-soft/40 p-3">
          <div className="flex items-center justify-between gap-2">
            <h3 className="text-sm font-semibold text-pending">
              Pendientes de confirmación · {pendingAppointments.length}
            </h3>
            <span className="text-[11px] font-medium text-pending/80">
              Nuevos turnos online
            </span>
          </div>
          {pendingError && (
            <p role="alert" className="mt-2 text-xs font-medium text-expense">{pendingError}</p>
          )}
          <ul className="mt-2 space-y-2">
            {pendingAppointments.map((appointment) => (
              <li key={appointment.id} className="rounded-lg border border-base bg-surface p-3">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-semibold">
                      {appointment.client_name_snapshot}
                    </p>
                    <p className="truncate text-xs text-muted">
                      {appointment.service?.name ?? 'Sin servicio'}
                      {appointment.staff ? ` · ${appointment.staff.name}` : ''}
                    </p>
                    <p className="numeric mt-1 text-xs text-muted">
                      {zonedTime(appointment.starts_at, shop.timezone)}–
                      {zonedTime(appointment.ends_at, shop.timezone)} ·{' '}
                      {dateKeyLongLabel(
                        shopDateKey(new Date(appointment.starts_at), shop.timezone),
                      )}
                    </p>
                  </div>
                  <div className="flex shrink-0 gap-1">
                    <button
                      type="button"
                      disabled={pendingBusyId !== null}
                      onClick={() => void acceptPending(appointment)}
                      className="inline-flex min-h-[44px] items-center rounded-lg border border-income/40 bg-income-soft px-2 text-xs font-semibold text-income hover:bg-income/10 disabled:opacity-60"
                    >
                      {pendingBusyId === appointment.id ? '…' : 'Aceptar'}
                    </button>
                    <button
                      type="button"
                      disabled={pendingBusyId !== null}
                      onClick={() => {
                        setRejectingId(appointment.id)
                        setRejectReason('')
                      }}
                      className="inline-flex min-h-[44px] items-center rounded-lg border border-expense/40 bg-expense-soft px-2 text-xs font-semibold text-expense hover:bg-expense/10 disabled:opacity-60"
                    >
                      Rechazar
                    </button>
                  </div>
                </div>
                {rejectingId === appointment.id && (
                  <div className="mt-2 space-y-2">
                    <textarea
                      value={rejectReason}
                      onChange={(event) => setRejectReason(event.target.value)}
                      placeholder="Motivo del rechazo (el cliente lo verá)…"
                      className="min-h-[64px] w-full rounded-lg border border-base bg-surface px-3 py-2 text-sm"
                      maxLength={300}
                    />
                    <div className="flex gap-2">
                      <button
                        type="button"
                        onClick={() => {
                          setRejectingId(null)
                          setRejectReason('')
                        }}
                        className="inline-flex min-h-[44px] flex-1 items-center justify-center rounded-lg border border-base bg-surface text-xs font-semibold text-muted"
                      >
                        Cancelar
                      </button>
                      <button
                        type="button"
                        disabled={pendingBusyId !== null}
                        onClick={() => void rejectPending(appointment)}
                        className="inline-flex min-h-[44px] flex-1 items-center justify-center rounded-lg border border-expense bg-expense-soft text-xs font-semibold text-expense"
                      >
                        {pendingBusyId === appointment.id ? '…' : 'Confirmar rechazo'}
                      </button>
                    </div>
                  </div>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="mt-4 flex items-center justify-between gap-2 rounded-xl border border-base bg-surface p-1.5">
        <button
          type="button"
          onClick={() => moveDay(-1)}
          aria-label="Día anterior"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronLeft size={18} aria-hidden="true" />
        </button>
        <button
          type="button"
          onClick={() => {
            setDateKey(today)
            setReminderError(null)
          }}
          className="min-w-0 flex-1 rounded-lg px-1 py-1 text-center"
          aria-label={dateKey === today ? 'Hoy' : 'Volver a hoy'}
        >
          <span className="block truncate text-sm font-semibold">{dateKeyLongLabel(dateKey)}</span>
          <span className="text-[11px] text-muted">{dateKey === today ? 'Hoy' : 'Volver a hoy'}</span>
        </button>
        <button
          type="button"
          onClick={() => moveDay(1)}
          aria-label="Día siguiente"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronRight size={18} aria-hidden="true" />
        </button>
      </div>

      <div className="-mx-5 mt-3 flex gap-1.5 overflow-x-auto px-5 pb-1">
        <button
          type="button"
          onClick={() => setStaffFilter('all')}
          aria-pressed={staffFilter === 'all'}
          className={`min-h-[44px] shrink-0 rounded-lg border px-3 text-xs font-semibold ${
            staffFilter === 'all'
              ? 'border-strong bg-surface text-ink'
              : 'border-base bg-surface text-muted'
          }`}
        >
          Todos
        </button>
        {activeStaff.map((member) => {
          const selected = staffFilter === member.id
          return (
            <button
              key={member.id}
              type="button"
              onClick={() => setStaffFilter(member.id)}
              aria-pressed={selected}
              className={`inline-flex min-h-[44px] shrink-0 items-center gap-2 rounded-lg border px-3 text-xs font-semibold ${
                selected
                  ? 'border-strong bg-surface text-ink'
                  : 'border-base bg-surface text-muted'
              }`}
            >
              <span
                aria-hidden="true"
                className="size-2.5 rounded-full border border-strong/20"
                style={{ backgroundColor: member.color_hex }}
              />
              {member.name}
            </button>
          )
        })}
      </div>

      {reminderError && (
        <p
          role="alert"
          className="mt-2 rounded-lg border border-base bg-expense-soft/40 px-3 py-2 text-xs font-medium text-expense"
        >
          {reminderError}
        </p>
      )}

      <div className="mt-2 flex items-center justify-between gap-2">
        <p className="numeric text-xs text-muted">
          {loading
            ? 'Cargando…'
            : `${activeAppointments.length} ${activeAppointments.length === 1 ? 'turno' : 'turnos'}${
                activeAppointments.length > 0 ? ` · ${durationLabel(totalMinutes)}` : ''
              }`}
        </p>
        <button
          type="button"
          onClick={onOpenClients}
          className="inline-flex min-h-[44px] items-center gap-1.5 px-1 text-xs font-semibold text-muted hover:text-ink"
        >
          <UserRound size={15} aria-hidden="true" />
          Clientes
        </button>
      </div>

      {loading && (
        <p className="mt-3 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando agenda…
        </p>
      )}

      {!loading && error && (
        <div className="mt-3 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm text-ink">{error}</p>
          <div className="mt-3">
            <Button type="button" variant="secondary" onClick={() => void reload()}>
              Reintentar
            </Button>
          </div>
        </div>
      )}

      {!loading && !error && filtered.length === 0 && (
        <div className="mt-3 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">Sin turnos para este día.</p>
          <p className="mt-1 text-xs text-muted">
            {staffFilter === 'all'
              ? 'Agendá el primero o cambiá de fecha.'
              : 'Este profesional no tiene turnos cargados.'}
          </p>
          <div className="mt-4">
            <Button type="button" onClick={() => setFormOpen(true)}>
              Agendar turno
            </Button>
          </div>
        </div>
      )}

      {filtered.length > 0 && (
        <ul className="mt-1 space-y-2">
          {filtered.map((appointment) => {
            const meta = STATUS_META[appointment.status]
            const staffColor = appointment.staff?.color_hex ?? '#1E3A2F'

            return (
              <li
                key={appointment.id}
                className="rounded-xl border border-base bg-surface p-3"
              >
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span
                        aria-hidden="true"
                        className="size-2.5 shrink-0 rounded-full border border-strong/20"
                        style={{ backgroundColor: staffColor }}
                      />
                      <p className="numeric text-sm font-bold">
                        {zonedTime(appointment.starts_at, shop.timezone)}–
                        {zonedTime(appointment.ends_at, shop.timezone)}
                      </p>
                      {appointment.source === 'walk_in' && (
                        <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Al paso
                        </span>
                      )}
                      {appointment.sync_status && (
                        <span
                          className={`rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                            appointment.sync_status === 'failed'
                              ? 'bg-expense-soft text-expense'
                              : 'bg-pending-soft text-pending'
                          }`}
                        >
                          {appointment.sync_status === 'failed'
                            ? 'Sin sincronizar'
                            : 'Guardado local'}
                        </span>
                      )}
                    </div>
                    <p className="mt-1 truncate text-sm font-semibold">
                      {appointment.client_name_snapshot}
                    </p>
                    <p className="truncate text-xs text-muted">
                      {appointment.service?.name ?? 'Sin servicio'}
                      {staffFilter === 'all' && appointment.staff
                        ? ` · ${appointment.staff.name}`
                        : ''}
                    </p>
                    {appointment.notes && (
                      <p className="mt-1 line-clamp-2 text-xs text-muted">{appointment.notes}</p>
                    )}
                  </div>
                  <span
                    className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${meta.className}`}
                  >
                    {meta.label}
                  </span>
                </div>

                <div className="mt-1 flex items-center justify-between gap-2">
                  <a
                    href={`tel:${appointment.client_phone_snapshot.replace(/[^\d+]/g, '')}`}
                    className="numeric inline-flex min-h-[44px] min-w-0 items-center gap-1.5 text-xs text-muted hover:text-ink"
                  >
                    <Phone size={13} className="shrink-0" aria-hidden="true" />
                    <span className="truncate">{appointment.client_phone_snapshot}</span>
                  </a>
                  <div className="flex shrink-0 items-center gap-1">
                    {isRemindable(appointment.status) && (
                      <button
                        type="button"
                        onClick={() => void sendReminder(appointment)}
                        disabled={reminderBusyId !== null}
                        aria-label={
                          appointment.reminder_sent
                            ? 'Reenviar recordatorio por WhatsApp'
                            : 'Recordar por WhatsApp'
                        }
                        title="Recordar por WhatsApp"
                        className="flex size-11 items-center justify-center rounded-lg border border-base text-muted hover:bg-surface-alt hover:text-ink disabled:opacity-60"
                      >
                        {reminderBusyId === appointment.id ? (
                          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
                        ) : (
                          <MessageCircle
                            size={16}
                            aria-hidden="true"
                            className={appointment.reminder_sent ? 'text-income' : undefined}
                          />
                        )}
                      </button>
                    )}
                    <button
                      type="button"
                      onClick={() => setSelected(appointment)}
                      className="inline-flex min-h-[44px] items-center gap-0.5 rounded-lg px-2 text-xs font-semibold text-muted hover:bg-surface-alt hover:text-ink"
                    >
                      Ver turno
                      <ChevronRight size={14} aria-hidden="true" />
                    </button>
                  </div>
                </div>
              </li>
            )
          })}
        </ul>
      )}

      <Modal open={selected !== null} title="Turno" onClose={() => setSelected(null)}>
        {selected && (
          <AppointmentDetail
            key={selected.id}
            shop={shop}
            appointment={selected}
            onUpdated={(updated) => {
              setSelected((current) =>
                current && current.id === updated.id ? updated : current,
              )
              void reload()
            }}
          />
        )}
      </Modal>

      <Modal
        open={formOpen}
        title="Nuevo turno"
        onClose={() => setFormOpen(false)}
      >
        <AppointmentForm
          shop={shop}
          staff={activeStaff}
          services={activeServices}
          dateKey={dateKey}
          initialStaffId={staffFilter === 'all' ? undefined : staffFilter}
          onSaved={(message) => {
            setFormOpen(false)
            setNotice(message ?? null)
            void reload()
          }}
          onCancel={() => setFormOpen(false)}
        />
      </Modal>
    </section>
  )
}

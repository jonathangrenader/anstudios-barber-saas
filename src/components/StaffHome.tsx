import { useState } from 'react'
import {
  CalendarDays,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Loader2,
  LogOut,
  Pencil,
  Plus,
  Phone,
  Play,
  Scissors,
  UserX,
} from 'lucide-react'
import { useMyAgenda } from '../hooks/useMyAgenda'
import { useCatalog } from '../hooks/useCatalog'
import {
  addDaysToDateKey,
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import { listStaff } from '../lib/staff'
import { setMyAppointmentStatus, updateMyProfile, updateMySchedule } from '../lib/staff'
import { reassignAppointment, rescheduleAppointment } from '../lib/appointments'
import { STATUS_META } from '../lib/status'
import type { AppointmentStatus } from '../types/appointment'
import type { StaffAgendaItem, StaffContext, StaffMember } from '../types/staff'
import { AppointmentForm } from './AppointmentForm'
import { CalendarFeedSection } from './CalendarFeedSection'
import { Modal } from './ui/Modal'
import { Button, FieldError, Textarea } from './ui/controls'
import { PhotoPicker } from './ui/PhotoPicker'

const ACTIVE_STATUSES: AppointmentStatus[] = ['pending', 'confirmed', 'in_progress']

function durationLabel(minutes: number): string {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  if (hours === 0) return `${rest}m`
  return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`
}

export function StaffHome({
  context,
  online,
  onSignOut,
  onProfileSaved,
}: {
  context: StaffContext
  online: boolean
  onSignOut: () => void
  onProfileSaved: (photoUrl: string | null, bio: string | null) => void
}) {
  const today = shopDateKey(new Date(), context.shop_timezone)
  const [dateKey, setDateKey] = useState(today)
  const { appointments, loading, error, reload } = useMyAgenda(dateKey)
  const { items: catalogItems } = useCatalog(context.shop_id)
  const [formOpen, setFormOpen] = useState(false)

  const selfStaff = {
    id: context.staff_id,
    shop_id: context.shop_id,
    user_id: null,
    name: context.staff_name,
    role: context.staff_role,
    phone: null,
    commission_pct: 0,
    product_commission_pct: 0,
    is_active: context.staff_active,
    color_hex: context.staff_color,
    photo_url: context.staff_photo,
    bio: context.staff_bio,
    can_book_appointments: context.staff_can_book_appointments ?? false,
    created_at: new Date().toISOString(),
  }

  const selfShop = {
    id: context.shop_id,
    owner_id: '',
    name: context.shop_name,
    slug: context.shop_slug,
    phone: context.shop_phone,
    address: context.shop_address,
    description: null,
    whatsapp: null,
    phone_landline: null,
    phone_mobile: null,
    maps_url: null,
    photo_url: null,
    timezone: context.shop_timezone,
    open_time: context.shop_open_time,
    close_time: context.shop_close_time,
    slot_duration_min: context.shop_slot_duration_min ?? 30,
    professionals_can_book:
      context.shop_professional_booking_mode === 'all' ||
      (context.shop_professional_booking_mode === 'per_staff' && !!context.staff_can_book_appointments) ||
      (!context.shop_professional_booking_mode && !!context.staff_can_book_appointments),
    is_suspended: false,
    suspended_at: null,
    suspension_note: null,
    trial_ends_at: null,
    created_at: new Date().toISOString(),
  }

  const [updatingId, setUpdatingId] = useState<string | null>(null)
  const [actionError, setActionError] = useState<{ id: string; message: string } | null>(null)

  const [profileOpen, setProfileOpen] = useState(false)
  const [profilePhoto, setProfilePhoto] = useState<string | null>(context.staff_photo)
  const [profileBio, setProfileBio] = useState(context.staff_bio ?? '')
  const [profileSaving, setProfileSaving] = useState(false)
  const [profileError, setProfileError] = useState<string | null>(null)

  const [scheduleOpen, setScheduleOpen] = useState(false)
  const [scheduleDays, setScheduleDays] = useState<number[]>(context.staff_working_days ?? [1, 2, 3, 4, 5])
  const [scheduleStart, setScheduleStart] = useState(context.staff_work_start_time ?? context.shop_open_time)
  const [scheduleEnd, setScheduleEnd] = useState(context.staff_work_end_time ?? context.shop_close_time)
  const [scheduleSaving, setScheduleSaving] = useState(false)
  const [scheduleError, setScheduleError] = useState<string | null>(null)

  const [manageOpen, setManageOpen] = useState(false)
  const [managedAppointment, setManagedAppointment] = useState<StaffAgendaItem | null>(null)
  const [manageStaffList, setManageStaffList] = useState<StaffMember[]>([])
  const [manageStaffId, setManageStaffId] = useState('')
  const [manageTime, setManageTime] = useState('')
  const [manageBusy, setManageBusy] = useState(false)
  const [manageError, setManageError] = useState<string | null>(null)
  const [manageNotice, setManageNotice] = useState<string | null>(null)

  const activeAppointments = appointments.filter((appointment) =>
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

  async function changeStatus(
    id: string,
    status: 'in_progress' | 'completed' | 'no_show',
  ) {
    setUpdatingId(id)
    setActionError(null)
    try {
      await setMyAppointmentStatus(id, status)
      await reload()
    } catch (err) {
      setActionError({
        id,
        message: err instanceof Error ? err.message : 'No pudimos actualizar el turno.',
      })
    } finally {
      setUpdatingId(null)
    }
  }

  async function saveProfile() {
    setProfileSaving(true)
    setProfileError(null)
    try {
      await updateMyProfile(profilePhoto, profileBio)
      onProfileSaved(profilePhoto, profileBio.trim() || null)
      setProfileOpen(false)
    } catch (err) {
      setProfileError(err instanceof Error ? err.message : 'No pudimos guardar tu perfil.')
    } finally {
      setProfileSaving(false)
    }
  }

  async function saveSchedule() {
    setScheduleSaving(true)
    setScheduleError(null)
    try {
      await updateMySchedule(
        scheduleDays.length ? scheduleDays : null,
        scheduleStart || null,
        scheduleEnd || null,
      )
      setScheduleOpen(false)
    } catch (err) {
      setScheduleError(err instanceof Error ? err.message : 'No pudimos guardar tu agenda.')
    } finally {
      setScheduleSaving(false)
    }
  }

  function openManage(appointment: StaffAgendaItem) {
    setManagedAppointment(appointment)
    setManageStaffId(context.staff_id)
    setManageTime('')
    setManageError(null)
    setManageNotice(null)
    void listStaff(context.shop_id).then(setManageStaffList).catch(() => setManageStaffList([]))
    setManageOpen(true)
  }

  async function handleManageReassign() {
    if (!managedAppointment || !manageStaffId) return
    setManageBusy(true)
    setManageError(null)
    setManageNotice(null)
    try {
      await reassignAppointment(managedAppointment.id, manageStaffId)
      setManageNotice('Turno reasignado.')
    } catch (err) {
      setManageError(err instanceof Error ? err.message : 'No pudimos reasignar el turno.')
    } finally {
      setManageBusy(false)
    }
  }

  async function handleManageReschedule() {
    if (!managedAppointment || !manageTime) return
    setManageBusy(true)
    setManageError(null)
    setManageNotice(null)
    try {
      await rescheduleAppointment(managedAppointment.id, `${manageTime}:00-03:00`)
      setManageNotice('Turno reprogramado.')
    } catch (err) {
      setManageError(err instanceof Error ? err.message : 'No pudimos reprogramar el turno.')
    } finally {
      setManageBusy(false)
    }
  }

  function notifyManagedClient(message: string) {
    if (!managedAppointment) return
    const phone = managedAppointment.client_phone.replace(/\D/g, '')
    if (!phone) {
      setManageError('El teléfono del cliente no permite armar el link de WhatsApp.')
      return
    }
    window.open(`https://wa.me/549${phone.slice(-10)}?text=${encodeURIComponent(message)}`, '_blank', 'noopener,noreferrer')
  }

  return (
    <main className="mx-auto w-full max-w-md px-5 pb-10 pt-8">
      <header className="mb-6 flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-start gap-3">
          {context.staff_photo ? (
            <img
              src={context.staff_photo}
              alt=""
              className="size-11 shrink-0 rounded-full border border-base object-cover"
            />
          ) : (
            <span
              aria-hidden="true"
              className="flex size-11 shrink-0 items-center justify-center rounded-full border border-base bg-surface-alt text-sm font-bold text-ink"
            >
              {context.staff_name.slice(0, 1).toUpperCase()}
            </span>
          )}
          <div className="min-w-0">
            <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">
              {context.shop_name}
            </p>
            <h1 className="truncate text-xl font-bold leading-tight">{context.staff_name}</h1>
            <p className="mt-0.5 flex items-center gap-1.5 text-xs text-muted">
              <span
                aria-hidden="true"
                className="size-2.5 rounded-full border border-strong/20"
                style={{ backgroundColor: context.staff_color }}
              />
              {context.staff_role}
            </p>
          </div>
        </div>
        <div className="flex shrink-0 flex-col items-end gap-1">
          <button
            type="button"
            onClick={onSignOut}
            className="inline-flex min-h-[44px] items-center gap-2 rounded-lg border border-base bg-surface px-3 text-sm font-medium text-muted hover:bg-surface-alt"
          >
            <LogOut size={16} aria-hidden="true" />
            Salir
          </button>
          {context.staff_active && (
            <button
              type="button"
              onClick={() => {
                setProfilePhoto(context.staff_photo)
                setProfileBio(context.staff_bio ?? '')
                setProfileError(null)
                setProfileOpen(true)
              }}
              className="inline-flex min-h-[44px] items-center gap-1.5 px-1 text-xs font-semibold text-ink underline decoration-base underline-offset-4 hover:decoration-strong"
            >
              <Pencil size={13} aria-hidden="true" />
              Mi perfil
            </button>
          )}
          {context.staff_active && (
            <button
              type="button"
              onClick={() => {
                setScheduleDays(context.staff_working_days ?? [1, 2, 3, 4, 5])
                setScheduleStart(context.staff_work_start_time ?? context.shop_open_time)
                setScheduleEnd(context.staff_work_end_time ?? context.shop_close_time)
                setScheduleError(null)
                setScheduleOpen(true)
              }}
              className="inline-flex min-h-[44px] items-center gap-1.5 px-1 text-xs font-semibold text-ink underline decoration-base underline-offset-4 hover:decoration-strong"
            >
              <CalendarDays size={13} aria-hidden="true" />
              Mi horario
            </button>
          )}
        </div>
      </header>

      {!context.staff_active && (
        <p
          role="status"
          className="mb-3 rounded-lg border border-expense/30 bg-expense-soft px-3 py-2 text-xs font-medium text-expense"
        >
          Tu acceso está desactivado. El local puede reactivar tu ficha para que vuelvas a
          ver tu agenda.
        </p>
      )}

      {!online && (
        <p
          role="status"
          className="mb-3 rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending"
        >
          Sin conexión. La agenda del profesional se consulta online; reconectá para ver
          los turnos.
        </p>
      )}

      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-bold">Mi agenda</h2>
          <p className="mt-0.5 text-xs text-muted">Solo tus turnos del día.</p>
        </div>
        {(context.shop_professional_booking_mode === 'all' ||
          (context.shop_professional_booking_mode === 'per_staff' && !!context.staff_can_book_appointments) ||
          (!context.shop_professional_booking_mode && !!context.staff_can_book_appointments)) &&
          context.staff_active && (
          <button
            type="button"
            onClick={() => setFormOpen(true)}
            className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-3 text-sm font-semibold text-white shadow-tactile"
          >
            <Plus size={16} aria-hidden="true" />
            Nuevo turno
          </button>
        )}
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-base bg-surface text-muted">
          <CalendarDays size={20} aria-hidden="true" />
        </span>
      </div>

      <div className="mt-4 flex items-center justify-between gap-2 rounded-xl border border-base bg-surface p-1.5">
        <button
          type="button"
          onClick={() => setDateKey((current) => addDaysToDateKey(current, -1))}
          aria-label="Día anterior"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronLeft size={18} aria-hidden="true" />
        </button>
        <button
          type="button"
          onClick={() => setDateKey(today)}
          className="min-w-0 flex-1 rounded-lg px-1 py-1 text-center"
          aria-label={dateKey === today ? 'Hoy' : 'Volver a hoy'}
        >
          <span className="block truncate text-sm font-semibold">
            {dateKeyLongLabel(dateKey)}
          </span>
          <span className="text-[11px] text-muted">
            {dateKey === today ? 'Hoy' : 'Volver a hoy'}
          </span>
        </button>
        <button
          type="button"
          onClick={() => setDateKey((current) => addDaysToDateKey(current, 1))}
          aria-label="Día siguiente"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronRight size={18} aria-hidden="true" />
        </button>
      </div>

      <p className="numeric mt-2 text-xs text-muted">
        {loading
          ? 'Cargando…'
          : `${activeAppointments.length} ${
              activeAppointments.length === 1 ? 'turno activo' : 'turnos activos'
            }${activeAppointments.length > 0 ? ` · ${durationLabel(totalMinutes)}` : ''}`}
      </p>

      {loading && (
        <p className="mt-3 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando tu agenda…
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

      {!loading && !error && appointments.length === 0 && (
        <div className="mt-3 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">No tenés turnos para este día.</p>
          <p className="mt-1 text-xs text-muted">
            Si el local te asigna uno, aparece acá al actualizar.
          </p>
        </div>
      )}

      {appointments.length > 0 && (
        <ul className="mt-1 space-y-2">
          {appointments.map((appointment) => {
            const meta = STATUS_META[appointment.status]
            const busy = updatingId === appointment.id

            return (
              <li key={appointment.id} className="rounded-xl border border-base bg-surface p-3">
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="numeric text-sm font-bold">
                        {zonedTime(appointment.starts_at, context.shop_timezone)}–
                        {zonedTime(appointment.ends_at, context.shop_timezone)}
                      </p>
                      {appointment.source === 'walk_in' && (
                        <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Al paso
                        </span>
                      )}
                    </div>
                    <p className="mt-1 truncate text-sm font-semibold">
                      {appointment.client_name}
                    </p>
                    <p className="truncate text-xs text-muted">
                      {appointment.service_name ?? 'Sin servicio'}
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

                <a
                  href={`tel:${appointment.client_phone.replace(/[^\d+]/g, '')}`}
                  className="numeric mt-1 inline-flex min-h-[44px] w-full items-center gap-1.5 text-xs text-muted hover:text-ink"
                >
                  <Phone size={13} className="shrink-0" aria-hidden="true" />
                  <span className="truncate">{appointment.client_phone}</span>
                </a>

                {context.staff_active &&
                  (appointment.status === 'pending' || appointment.status === 'confirmed') && (
                    <div className="mt-1 grid grid-cols-2 gap-1.5">
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void changeStatus(appointment.id, 'in_progress')}
                        className="inline-flex min-h-[44px] items-center justify-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-2 text-xs font-semibold text-white disabled:opacity-60"
                      >
                        {busy ? (
                          <Loader2 size={14} className="animate-spin" aria-hidden="true" />
                        ) : (
                          <Play size={14} aria-hidden="true" />
                        )}
                        Iniciar
                      </button>
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void changeStatus(appointment.id, 'no_show')}
                        className="inline-flex min-h-[44px] items-center justify-center gap-1.5 rounded-lg border border-base bg-surface px-2 text-xs font-semibold text-muted hover:bg-surface-alt disabled:opacity-60"
                      >
                        <UserX size={14} aria-hidden="true" />
                        No vino
                      </button>
                    </div>
                  )}

                {context.staff_active && appointment.status === 'in_progress' && (
                  <div className="mt-1">
                    <button
                      type="button"
                      disabled={busy}
                      onClick={() => void changeStatus(appointment.id, 'completed')}
                      className="inline-flex min-h-[44px] w-full items-center justify-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-2 text-xs font-semibold text-white disabled:opacity-60"
                    >
                      {busy ? (
                        <Loader2 size={14} className="animate-spin" aria-hidden="true" />
                      ) : (
                        <CheckCircle2 size={14} aria-hidden="true" />
                      )}
                      Completar
                    </button>
                  </div>
                )}

                {context.shop_professionals_can_manage_appointments && context.staff_active && (
                  <button
                    type="button"
                    onClick={() => openManage(appointment)}
                    className="mt-1 inline-flex min-h-[44px] w-full items-center justify-center gap-1.5 rounded-lg border border-base bg-surface px-2 text-xs font-semibold text-muted hover:bg-surface-alt"
                  >
                    Gestionar turno
                  </button>
                )}

                {actionError?.id === appointment.id && (
                  <p role="alert" className="mt-1 text-xs font-medium text-expense">
                    {actionError.message}
                  </p>
                )}
              </li>
            )
          })}
        </ul>
      )}

      <p className="mt-5 flex items-start gap-1.5 border-t border-base pt-3 text-xs text-muted">
        <Scissors size={13} className="mt-0.5 shrink-0" aria-hidden="true" />
        Podés iniciar, completar o marcar la ausencia de tus turnos. Para cobrar,
        reprogramar o cambiar comisiones, hablá con el local.
      </p>

      <Modal open={manageOpen} title="Gestionar turno" onClose={() => setManageOpen(false)}>
        {managedAppointment && (
          <div className="space-y-4">
            <p className="text-sm font-semibold">{managedAppointment.client_name}</p>
            <p className="text-xs text-muted">
              {managedAppointment.service_name ?? 'Sin servicio'} ·{' '}
              {zonedTime(managedAppointment.starts_at, context.shop_timezone)}–
              {zonedTime(managedAppointment.ends_at, context.shop_timezone)}
            </p>

            <div>
              <label className="text-xs font-medium text-muted">Reasignar a</label>
              <div className="mt-1.5 flex gap-2">
                <select
                  value={manageStaffId}
                  onChange={(event) => setManageStaffId(event.target.value)}
                  className="min-h-[44px] flex-1 rounded-lg border border-base bg-surface px-3 text-sm"
                >
                  {manageStaffList.map((member) => (
                    <option key={member.id} value={member.id}>
                      {member.name}
                    </option>
                  ))}
                </select>
                <Button type="button" variant="secondary" loading={manageBusy} disabled={manageBusy} onClick={() => void handleManageReassign()}>
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
                <Button type="button" variant="secondary" loading={manageBusy} disabled={manageBusy || !manageTime} onClick={() => void handleManageReschedule()}>
                  Reprogramar
                </Button>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <Button type="button" variant="secondary" onClick={() => notifyManagedClient(`Hola, te avisamos que tu turno en ${context.shop_name} fue reasignado. Si no podés, avisanos.`)}>
                Avisar reasignación
              </Button>
              <Button type="button" variant="secondary" onClick={() => notifyManagedClient(`Hola, tu turno en ${context.shop_name} cambió de horario. Nuevo horario: ${manageTime || zonedTime(managedAppointment.starts_at, context.shop_timezone)}. Si no podés, avisanos.`)}>
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
        )}
      </Modal>

      <CalendarFeedSection staffId={context.staff_id} />

      <Modal
        open={formOpen}
        title="Nuevo turno"
        onClose={() => setFormOpen(false)}
      >
        <AppointmentForm
          shop={selfShop as any}
          staff={[selfStaff as any]}
          services={catalogItems.filter((item) => item.type === 'service' && item.is_active)}
          dateKey={dateKey}
          initialStaffId={context.staff_id}
          onSaved={() => {
            setFormOpen(false)
            void reload()
          }}
          onCancel={() => setFormOpen(false)}
        />
      </Modal>

      <Modal open={scheduleOpen} title="Mi horario de trabajo" onClose={() => setScheduleOpen(false)}>
        <div className="space-y-4">
          <p className="text-xs text-muted">
            Elegí los días en que trabajás y tu horario. Si no configurás nada, se usan
            los horarios del local.
          </p>
          <div className="grid grid-cols-7 gap-1.5">
            {['D', 'L', 'M', 'M', 'J', 'V', 'S'].map((label, day) => {
              const active = scheduleDays.includes(day)
              return (
                <button
                  key={day}
                  type="button"
                  onClick={() =>
                    setScheduleDays((current) =>
                      current.includes(day)
                        ? current.filter((d) => d !== day)
                        : [...current, day].sort(),
                    )
                  }
                  className={`flex size-11 items-center justify-center rounded-lg border text-xs font-semibold ${
                    active
                      ? 'border-strong bg-brand-primary text-white'
                      : 'border-base bg-surface text-muted'
                  }`}
                >
                  {label}
                </button>
              )
            })}
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-xs font-medium text-muted">Inicio</label>
              <input
                type="time"
                value={scheduleStart}
                onChange={(event) => setScheduleStart(event.target.value)}
                className="mt-1.5 min-h-[44px] w-full rounded-lg border border-base bg-surface px-3 text-sm"
              />
            </div>
            <div>
              <label className="text-xs font-medium text-muted">Fin</label>
              <input
                type="time"
                value={scheduleEnd}
                onChange={(event) => setScheduleEnd(event.target.value)}
                className="mt-1.5 min-h-[44px] w-full rounded-lg border border-base bg-surface px-3 text-sm"
              />
            </div>
          </div>
          <FieldError>{scheduleError}</FieldError>
          <Button type="button" loading={scheduleSaving} onClick={() => void saveSchedule()}>
            Guardar horario
          </Button>
        </div>
      </Modal>

      <Modal open={profileOpen} title="Mi perfil" onClose={() => setProfileOpen(false)}>
        <div className="space-y-4">
          <PhotoPicker
            label="Foto de perfil"
            prefix={`staff/${context.staff_id}`}
            value={profilePhoto}
            onChange={setProfilePhoto}
            disabled={profileSaving}
          />

          <div>
            <label htmlFor="staff-bio" className="text-xs font-medium text-muted">
              Descripción breve
            </label>
            <Textarea
              id="staff-bio"
              value={profileBio}
              maxLength={240}
              rows={3}
              onChange={(event) => setProfileBio(event.target.value)}
              placeholder="Ej.: Especialista en fades y color."
              className="mt-1.5"
            />
            <p className="numeric mt-1 text-right text-[11px] text-muted">
              {profileBio.length}/240
            </p>
          </div>

          <FieldError>{profileError}</FieldError>

          <Button type="button" loading={profileSaving} onClick={() => void saveProfile()}>
            Guardar perfil
          </Button>
        </div>
      </Modal>
    </main>
  )
}

import { useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle,
  CalendarClock,
  CheckCircle2,
  ChevronLeft,
  Loader2,
  MapPin,
  MessageCircle,
  Phone,
  Scissors,
} from 'lucide-react'
import {
  addDaysToDateKey,
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import {
  cancelPublicBooking,
  getManagedBooking,
  listPublicAvailability,
  PublicBookingError,
  reschedulePublicBooking,
} from '../lib/publicBooking'
import type {
  ManagedBooking,
  PublicAvailabilitySlot,
} from '../types/publicBooking'
import { Button, Input } from './ui/controls'

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const STATUS_LABELS: Record<string, string> = {
  pending: 'Pendiente de confirmación',
  confirmed: 'Confirmado',
  in_progress: 'En curso',
  completed: 'Completado',
  cancelled: 'Cancelado',
  no_show: 'Ausente',
}

function statusTone(status: string): string {
  if (status === 'cancelled' || status === 'no_show') {
    return 'border-expense/30 bg-expense-soft text-expense'
  }
  if (status === 'completed' || status === 'confirmed') {
    return 'border-income/30 bg-income-soft text-income'
  }
  return 'border-pending/30 bg-pending-soft text-pending'
}

function shortHour(value: string): string {
  return value.slice(0, 5)
}

function weekdayShort(dateKey: string): string {
  return new Intl.DateTimeFormat('es-AR', {
    weekday: 'short',
    timeZone: 'UTC',
  })
    .format(new Date(`${dateKey}T12:00:00Z`))
    .replace('.', '')
}

function BrandMark() {
  return (
    <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
      <Scissors size={22} strokeWidth={2} aria-hidden="true" />
    </span>
  )
}

function NoticePage({
  title,
  message,
  onRetry,
  onBack,
}: {
  title: string
  message: string
  onRetry?: () => void
  onBack?: () => void
}) {
  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center px-5 py-10">
      <section className="rounded-xl border border-base bg-surface p-5">
        <BrandMark />
        <p className="mt-4 text-xs font-semibold uppercase tracking-[0.14em] text-muted">
          ANSTUDIOS · Mi turno
        </p>
        <h1 className="mt-1 text-xl font-bold leading-tight">{title}</h1>
        <p className="mt-2 text-sm text-muted">{message}</p>
        <div className="mt-4 flex flex-wrap gap-2">
          {onRetry && (
            <Button type="button" onClick={onRetry}>
              Reintentar
            </Button>
          )}
          {onBack && (
            <Button type="button" variant="secondary" onClick={onBack}>
              Volver
            </Button>
          )}
        </div>
      </section>
    </main>
  )
}

export function ManageBookingPage({ token }: { token: string }) {
  const [booking, setBooking] = useState<ManagedBooking | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  const [rescheduling, setRescheduling] = useState(false)
  const [dateKey, setDateKey] = useState('')
  const [slots, setSlots] = useState<PublicAvailabilitySlot[]>([])
  const [slotsLoading, setSlotsLoading] = useState(false)
  const [slotsError, setSlotsError] = useState<string | null>(null)
  const [selectedSlot, setSelectedSlot] = useState<PublicAvailabilitySlot | null>(null)
  const [refreshKey, setRefreshKey] = useState(0)

  const [confirmingCancel, setConfirmingCancel] = useState(false)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)
  const [actionMessage, setActionMessage] = useState<string | null>(null)

  const validToken = UUID_PATTERN.test(token)
  const shop = booking?.shop ?? null
  const appointment = booking?.appointment ?? null

  useEffect(() => {
    if (!validToken) {
      setLoading(false)
      setLoadError('El link no es válido. Pedile al local un link actualizado.')
      return
    }

    let cancelled = false
    setLoading(true)
    setLoadError(null)

    getManagedBooking(token)
      .then((data) => {
        if (cancelled) return
        setBooking(data)
        setDateKey(shopDateKey(new Date(), data.shop.timezone))
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setLoadError(
            error instanceof Error ? error.message : 'No pudimos cargar tu turno.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [token, validToken, reloadKey])

  const today = useMemo(
    () => (shop ? shopDateKey(new Date(), shop.timezone) : ''),
    [shop],
  )
  const maxDate = useMemo(() => (today ? addDaysToDateKey(today, 90) : ''), [today])
  const days = useMemo(
    () => (today ? Array.from({ length: 7 }, (_, index) => addDaysToDateKey(today, index)) : []),
    [today],
  )

  const canReschedule = Boolean(
    appointment?.can_manage && appointment.service_id && appointment.staff_id,
  )

  useEffect(() => {
    if (!rescheduling || !shop || !appointment || !dateKey) return
    if (!appointment.service_id || !appointment.staff_id) return

    let cancelled = false
    setSlotsLoading(true)
    setSlotsError(null)

    listPublicAvailability(
      shop.slug,
      appointment.service_id,
      dateKey,
      appointment.staff_id,
    )
      .then((rows) => {
        if (cancelled) return
        setSlots(rows)
        setSelectedSlot((current) =>
          current && rows.some((row) => row.slot_start === current.slot_start)
            ? current
            : null,
        )
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setSlotsError(
            error instanceof Error
              ? error.message
              : 'No pudimos verificar la disponibilidad.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setSlotsLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [rescheduling, shop, appointment, dateKey, refreshKey])

  async function handleCancel() {
    if (busy || !appointment) return
    setBusy(true)
    setActionError(null)

    try {
      await cancelPublicBooking(token)
      setBooking((current) =>
        current
          ? {
              ...current,
              appointment: {
                ...current.appointment,
                status: 'cancelled',
                can_manage: false,
              },
            }
          : current,
      )
      setConfirmingCancel(false)
      setRescheduling(false)
      setActionMessage('Tu turno quedó cancelado. El local ya lo ve así en su agenda.')
    } catch (error) {
      setActionError(
        error instanceof Error ? error.message : 'No pudimos cancelar el turno.',
      )
    } finally {
      setBusy(false)
    }
  }

  async function handleReschedule() {
    if (busy || !selectedSlot) return
    setBusy(true)
    setActionError(null)

    try {
      const result = await reschedulePublicBooking(token, selectedSlot.slot_start)
      setBooking((current) =>
        current
          ? {
              ...current,
              appointment: {
                ...current.appointment,
                starts_at: result.starts_at,
                ends_at: result.ends_at,
                status: result.status,
                can_manage: true,
              },
            }
          : current,
      )
      setRescheduling(false)
      setSelectedSlot(null)
      setActionMessage(
        'Cambiamos tu horario. Queda pendiente de confirmación por el local.',
      )
      window.scrollTo({ top: 0, behavior: 'smooth' })
    } catch (error) {
      setActionError(
        error instanceof Error ? error.message : 'No pudimos cambiar el horario.',
      )
      if (
        error instanceof PublicBookingError &&
        (error.code === '23P01' || /horario/i.test(error.message))
      ) {
        setSelectedSlot(null)
        setRefreshKey((current) => current + 1)
      }
    } finally {
      setBusy(false)
    }
  }

  if (loading) {
    return (
      <main className="flex min-h-dvh flex-col items-center justify-center gap-3 px-5">
        <BrandMark />
        <p className="flex items-center gap-2 text-sm text-muted">
          <Loader2 size={15} className="animate-spin" aria-hidden="true" />
          Cargando tu turno…
        </p>
      </main>
    )
  }

  if (!booking || !shop || !appointment) {
    return (
      <NoticePage
        title="No encontramos este turno"
        message={loadError ?? 'El link puede haber vencido o el turno fue eliminado.'}
        onRetry={validToken ? () => setReloadKey((current) => current + 1) : undefined}
      />
    )
  }

  const statusLabel = STATUS_LABELS[appointment.status] ?? appointment.status
  const dateLabel = dateKeyLongLabel(
    shopDateKey(new Date(appointment.starts_at), shop.timezone),
  )
  const startLabel = zonedTime(appointment.starts_at, shop.timezone)
  const endLabel = zonedTime(appointment.ends_at, shop.timezone)
  const whatsapp = shop.whatsapp ?? shop.phone

  return (
    <main className="mx-auto w-full max-w-md px-5 pb-16 pt-8">
      <header className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <BrandMark />
          <div className="min-w-0">
            <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted">
              ANSTUDIOS · Mi turno
            </p>
            <h1 className="truncate text-xl font-bold leading-tight">{shop.name}</h1>
          </div>
        </div>
        <a
          href={`/r/${encodeURIComponent(shop.slug)}`}
          className="inline-flex min-h-[44px] shrink-0 items-center gap-1 text-xs font-semibold text-muted hover:text-ink"
        >
          <ChevronLeft size={14} aria-hidden="true" />
          Reservar
        </a>
      </header>

      {actionMessage && (
        <p
          role="status"
          className="mt-4 flex items-start gap-2 rounded-lg border border-income/30 bg-income-soft px-3 py-2.5 text-xs font-medium text-income"
        >
          <CheckCircle2 size={15} className="mt-0.5 shrink-0" aria-hidden="true" />
          {actionMessage}
        </p>
      )}

      <section className="mt-4 rounded-xl border border-base bg-surface p-4 sm:p-5">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <p className="text-xs text-muted">Turno de</p>
            <p className="text-base font-semibold">{appointment.client_name}</p>
          </div>
          <span
            className={`inline-flex items-center rounded-full border px-2.5 py-1 text-[11px] font-semibold ${statusTone(
              appointment.status,
            )}`}
          >
            {statusLabel}
          </span>
        </div>

        <dl className="mt-4 space-y-2 rounded-xl border border-base bg-surface-alt/60 p-3 text-sm">
          <div className="flex items-baseline justify-between gap-3">
            <dt className="text-xs text-muted">Servicio</dt>
            <dd className="text-right font-semibold">
              {appointment.service_name ?? 'Servicio'}
            </dd>
          </div>
          <div className="flex items-baseline justify-between gap-3">
            <dt className="text-xs text-muted">Profesional</dt>
            <dd className="text-right font-medium">
              {appointment.staff_name ?? 'A confirmar'}
            </dd>
          </div>
          <div className="flex items-baseline justify-between gap-3">
            <dt className="text-xs text-muted">Fecha</dt>
            <dd className="text-right font-medium">{dateLabel}</dd>
          </div>
          <div className="flex items-baseline justify-between gap-3">
            <dt className="text-xs text-muted">Horario</dt>
            <dd className="numeric text-right font-semibold">
              {startLabel}–{endLabel}
            </dd>
          </div>
        </dl>

        {appointment.notes && (
          <p className="mt-3 rounded-lg border border-base bg-surface-alt/60 px-3 py-2 text-xs text-muted">
            <span className="font-semibold text-ink">Nota: </span>
            {appointment.notes}
          </p>
        )}

        {(shop.address || whatsapp) && (
          <div className="mt-3 space-y-1.5 text-xs text-muted">
            {shop.address && (
              <p className="flex items-start gap-1.5">
                <MapPin size={13} className="mt-0.5 shrink-0" aria-hidden="true" />
                {shop.address}
              </p>
            )}
            {whatsapp && (
              <a
                href={`https://wa.me/${whatsapp.replace(/\D/g, '')}`}
                target="_blank"
                rel="noreferrer"
                className="inline-flex min-h-[44px] items-center gap-1.5 hover:text-ink"
              >
                <MessageCircle size={13} aria-hidden="true" />
                <span className="numeric">WhatsApp {whatsapp}</span>
              </a>
            )}
            {!whatsapp && shop.phone && (
              <a
                href={`tel:${shop.phone.replace(/[^\d+]/g, '')}`}
                className="inline-flex min-h-[44px] items-center gap-1.5 hover:text-ink"
              >
                <Phone size={13} aria-hidden="true" />
                <span className="numeric">{shop.phone}</span>
              </a>
            )}
          </div>
        )}

        {!appointment.can_manage && (
          <p className="mt-4 rounded-lg border border-base bg-surface-alt/60 px-3 py-2 text-xs text-muted">
            {appointment.status === 'cancelled'
              ? 'Este turno está cancelado. Si querés otro horario, reservá de nuevo.'
              : appointment.status === 'completed' || appointment.status === 'no_show'
                ? 'Este turno ya no se puede modificar.'
                : 'Faltan menos de 30 minutos o el turno ya comenzó. Hablá con el local para cambiarlo.'}
          </p>
        )}

        {actionError && (
          <p
            role="alert"
            className="mt-3 flex items-start gap-2 rounded-lg border border-expense/30 bg-expense-soft px-3 py-2 text-xs font-medium text-expense"
          >
            <AlertTriangle size={14} className="mt-0.5 shrink-0" aria-hidden="true" />
            {actionError}
          </p>
        )}

        {appointment.can_manage && !rescheduling && !confirmingCancel && (
          <div className="mt-4 grid gap-2">
            {canReschedule && (
              <Button
                type="button"
                variant="secondary"
                onClick={() => {
                  setRescheduling(true)
                  setActionError(null)
                  setActionMessage(null)
                  setConfirmingCancel(false)
                  setDateKey(today)
                }}
              >
                <CalendarClock size={16} aria-hidden="true" />
                Cambiar horario
              </Button>
            )}
            <Button
              type="button"
              variant="danger"
              onClick={() => {
                setConfirmingCancel(true)
                setActionError(null)
                setActionMessage(null)
              }}
            >
              Cancelar turno
            </Button>
          </div>
        )}

        {confirmingCancel && (
          <div className="mt-4 rounded-lg border border-expense/30 bg-expense-soft p-3">
            <p className="text-sm font-semibold text-expense">¿Cancelamos el turno?</p>
            <p className="mt-1 text-xs text-expense/80">
              Se libera el horario y el local lo ve al instante. No se puede deshacer desde
              este link.
            </p>
            <div className="mt-3 grid grid-cols-2 gap-2">
              <Button type="button" variant="secondary" onClick={() => setConfirmingCancel(false)}>
                Volver
              </Button>
              <Button
                type="button"
                variant="danger"
                loading={busy}
                onClick={() => void handleCancel()}
              >
                Sí, cancelar
              </Button>
            </div>
          </div>
        )}

        {rescheduling && (
          <div className="mt-4 rounded-xl border border-base bg-surface-alt/40 p-3">
            <div className="flex items-center justify-between gap-2">
              <h2 className="text-sm font-semibold">Elegí un nuevo horario</h2>
              <button
                type="button"
                onClick={() => {
                  setRescheduling(false)
                  setSelectedSlot(null)
                  setActionError(null)
                }}
                className="inline-flex min-h-[44px] items-center text-xs font-semibold text-muted underline underline-offset-4 hover:text-ink"
              >
                Cancelar cambio
              </button>
            </div>

            <div className="-mx-1 mt-2 flex gap-1.5 overflow-x-auto px-1 pb-1">
              {days.map((day, index) => {
                const active = day === dateKey
                return (
                  <button
                    key={day}
                    type="button"
                    aria-pressed={active}
                    aria-label={dateKeyLongLabel(day)}
                    onClick={() => {
                      setDateKey(day)
                      setSelectedSlot(null)
                      setActionError(null)
                    }}
                    className={`flex min-h-[54px] min-w-[52px] shrink-0 flex-col items-center justify-center rounded-lg border px-2 transition-colors ${
                      active
                        ? 'border-strong bg-brand-primary text-white'
                        : 'border-base bg-surface text-ink hover:border-strong'
                    }`}
                  >
                    <span
                      className={`text-[10px] font-semibold uppercase tracking-wide ${
                        active ? 'text-white/80' : 'text-muted'
                      }`}
                    >
                      {index === 0 ? 'Hoy' : weekdayShort(day)}
                    </span>
                    <span className="numeric text-base font-bold leading-tight">
                      {Number(day.slice(8, 10))}
                    </span>
                  </button>
                )
              })}
            </div>

            <div className="mt-2 space-y-1.5">
              <label htmlFor="manage-date" className="text-xs font-medium text-muted">
                Otra fecha
              </label>
              <Input
                id="manage-date"
                type="date"
                min={today}
                max={maxDate}
                value={dateKey}
                onChange={(event) => {
                  if (event.target.value) {
                    setDateKey(event.target.value)
                    setSelectedSlot(null)
                    setActionError(null)
                  }
                }}
                className="numeric"
              />
            </div>

            <div className="mt-3">
              {slotsLoading && (
                <p className="flex min-h-[44px] items-center gap-2 text-sm text-muted">
                  <Loader2 size={16} className="animate-spin" aria-hidden="true" />
                  Verificando disponibilidad…
                </p>
              )}

              {!slotsLoading && slotsError && (
                <div className="rounded-lg border border-base bg-surface px-3 py-2.5">
                  <p role="alert" className="text-xs font-medium text-expense">
                    {slotsError}
                  </p>
                  <button
                    type="button"
                    onClick={() => setRefreshKey((current) => current + 1)}
                    className="mt-1 inline-flex min-h-[44px] items-center text-xs font-semibold text-ink underline underline-offset-4"
                  >
                    Reintentar
                  </button>
                </div>
              )}

              {!slotsLoading && !slotsError && slots.length === 0 && (
                <p className="rounded-lg border border-base bg-surface px-3 py-2.5 text-xs text-muted">
                  No quedan horarios libres ese día
                  {appointment.staff_name ? ` con ${appointment.staff_name}` : ''}. Probá otra
                  fecha.
                </p>
              )}

              {!slotsLoading && !slotsError && slots.length > 0 && (
                <div className="grid grid-cols-4 gap-1.5" role="group" aria-label="Horarios disponibles">
                  {slots.map((slot) => {
                    const active = selectedSlot?.slot_start === slot.slot_start
                    return (
                      <button
                        key={slot.slot_start}
                        type="button"
                        aria-pressed={active}
                        onClick={() => {
                          setSelectedSlot(slot)
                          setActionError(null)
                        }}
                        className={`numeric min-h-[44px] rounded-lg border text-xs font-semibold transition-colors ${
                          active
                            ? 'border-strong bg-brand-primary text-white'
                            : 'border-base bg-surface text-ink hover:border-strong'
                        }`}
                      >
                        {shortHour(zonedTime(slot.slot_start, shop.timezone))}
                      </button>
                    )
                  })}
                </div>
              )}
            </div>

            <div className="mt-3">
              <Button
                type="button"
                loading={busy}
                disabled={!selectedSlot}
                onClick={() => void handleReschedule()}
              >
                Confirmar nuevo horario
              </Button>
              <p className="mt-1.5 text-center text-[11px] text-muted">
                El turno vuelve a quedar pendiente hasta que el local confirme.
              </p>
            </div>
          </div>
        )}
      </section>

      <p className="mt-5 text-center text-[11px] text-muted">
        Guardá este link para cancelar o cambiar tu turno.
      </p>
    </main>
  )
}

import { useEffect, useMemo, useState, type FormEvent, type ReactNode } from 'react'
import {
  Check,
  CheckCircle2,
  Clock,
  Loader2,
  MapPin,
  MessageCircle,
  Phone,
  Scissors,
} from 'lucide-react'
import { normalizePhone } from '../lib/clients'
import {
  addDaysToDateKey,
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import { formatMoney } from '../lib/format'
import {
  createPublicBooking,
  findPublicAppointments,
  getPublicShop,
  listPublicAvailability,
  PublicBookingError,
} from '../lib/publicBooking'
import type {
  PublicAvailabilitySlot,
  PublicBookingResult,
  PublicShop,
  PublicShopData,
} from '../types/publicBooking'
import { Button, FieldError, Input, Textarea } from './ui/controls'

type FieldErrors = Partial<Record<'name' | 'phone' | 'notes' | 'slot', string>>

function weekdayShort(dateKey: string): string {
  return new Intl.DateTimeFormat('es-AR', {
    weekday: 'short',
    timeZone: 'UTC',
  })
    .format(new Date(`${dateKey}T12:00:00Z`))
    .replace('.', '')
}

function dayNumber(dateKey: string): string {
  return String(Number(dateKey.slice(8, 10)))
}

function shortTime(value: string): string {
  return value.slice(0, 5)
}

function icsDate(value: string): string {
  return new Date(value).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
}

function buildCalendarFile(result: PublicBookingResult, shop: PublicShop, reminders: boolean): string {
  const alarms = reminders
    ? [
        'BEGIN:VALARM',
        'TRIGGER:-P1D',
        'ACTION:DISPLAY',
        'DESCRIPTION:Recordatorio de turno',
        'END:VALARM',
        'BEGIN:VALARM',
        'TRIGGER:-PT2H',
        'ACTION:DISPLAY',
        'DESCRIPTION:Recordatorio de turno',
        'END:VALARM',
      ].join('\r\n')
    : ''

  return [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//ANSTUDIOS//Reserva//ES',
    'CALSCALE:GREGORIAN',
    'BEGIN:VEVENT',
    `UID:${result.appointment_id}@anstudios`,
    `DTSTART:${icsDate(result.starts_at)}`,
    `DTEND:${icsDate(result.ends_at)}`,
    `SUMMARY:${result.service_name} - ${shop.name}`,
    `DESCRIPTION:Profesional: ${result.staff_name}\\nLocal: ${shop.name}`,
    shop.address ? `LOCATION:${shop.address}` : '',
    alarms,
    'END:VEVENT',
    'END:VCALENDAR',
  ]
    .filter(Boolean)
    .join('\r\n')
}

function downloadCalendar(result: PublicBookingResult, shop: PublicShop, reminders: boolean) {
  const content = buildCalendarFile(result, shop, reminders)
  const blob = new Blob([content], { type: 'text/calendar;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `turno-${result.appointment_id}.ics`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

function BrandMark() {
  return (
    <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
      <Scissors size={22} strokeWidth={2} aria-hidden="true" />
    </span>
  )
}

function PublicLoading() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-3 px-5">
      <BrandMark />
      <p className="flex items-center gap-2 text-sm text-muted">
        <Loader2 size={15} className="animate-spin" aria-hidden="true" />
        Cargando reserva…
      </p>
    </main>
  )
}

function NoticePage({
  title,
  message,
  onRetry,
}: {
  title: string
  message: string
  onRetry?: () => void
}) {
  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center px-5 py-10">
      <section className="rounded-xl border border-base bg-surface p-5">
        <BrandMark />
        <p className="mt-4 text-xs font-semibold uppercase tracking-[0.14em] text-muted">
          ANSTUDIOS · Reserva online
        </p>
        <h1 className="mt-1 text-xl font-bold leading-tight">{title}</h1>
        <p className="mt-2 text-sm text-muted">{message}</p>
        {onRetry && (
          <div className="mt-4">
            <Button type="button" onClick={onRetry}>
              Reintentar
            </Button>
          </div>
        )}
      </section>
    </main>
  )
}

function ShopHeader({ shop }: { shop: PublicShop }) {
  const whatsapp = shop.whatsapp ?? shop.phone_mobile ?? shop.phone
  const maps =
    shop.maps_url ??
    (shop.address
      ? `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(shop.address)}`
      : null)

  return (
    <header>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[11px] font-semibold uppercase tracking-[0.14em] text-muted">
            ANSTUDIOS · Reserva online
          </p>
          <h1 className="mt-1 text-2xl font-bold leading-tight">{shop.name}</h1>
          <p className="mt-1 text-sm text-muted">
            {shop.description || 'Elegí servicio, profesional y horario.'}
          </p>
        </div>
        {shop.photo_url ? (
          <img
            src={shop.photo_url}
            alt={shop.name}
            className="size-14 shrink-0 rounded-xl border border-base object-cover"
          />
        ) : (
          <BrandMark />
        )}
      </div>

      {shop.photo_url && (
        <img
          src={shop.photo_url}
          alt=""
          className="mt-3 h-36 w-full rounded-xl border border-base object-cover"
        />
      )}

      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 text-xs text-muted">
        {shop.address && (
          <span className="inline-flex items-center gap-1.5">
            <MapPin size={13} aria-hidden="true" />
            {shop.address}
          </span>
        )}
        <span className="inline-flex items-center gap-1.5">
          <Clock size={13} aria-hidden="true" />
          <span className="numeric">
            {shortTime(shop.open_time)}–{shortTime(shop.close_time)}
          </span>
          <span>· turnos de {shop.slot_duration_min} min</span>
        </span>
        {whatsapp && (
          <a
            href={`https://wa.me/${whatsapp.replace(/\D/g, '')}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-[32px] items-center gap-1.5 hover:text-ink"
          >
            <MessageCircle size={13} aria-hidden="true" />
            <span className="numeric">WhatsApp {whatsapp}</span>
          </a>
        )}
        {shop.phone_landline && (
          <a
            href={`tel:${shop.phone_landline.replace(/[^\d+]/g, '')}`}
            className="inline-flex min-h-[32px] items-center gap-1.5 hover:text-ink"
          >
            <Phone size={13} aria-hidden="true" />
            <span className="numeric">{shop.phone_landline}</span>
          </a>
        )}
        {maps && (
          <a
            href={maps}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-[32px] items-center gap-1.5 hover:text-ink"
          >
            <MapPin size={13} aria-hidden="true" />
            Cómo llegar
          </a>
        )}
      </div>
    </header>
  )
}

function Step({
  index,
  title,
  children,
}: {
  index: string
  title: string
  children: ReactNode
}) {
  return (
    <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
      <div className="flex items-baseline gap-2">
        <span className="numeric text-[11px] font-bold text-muted">{index}</span>
        <h2 className="text-sm font-semibold">{title}</h2>
      </div>
      <div className="mt-3">{children}</div>
    </section>
  )
}

export function PublicBookingPage({ slug }: { slug: string }) {
  const [shopData, setShopData] = useState<PublicShopData | null>(null)
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)

  const [serviceId, setServiceId] = useState('')
  const [staffId, setStaffId] = useState('')
  const [dateKey, setDateKey] = useState('')
  const [slots, setSlots] = useState<PublicAvailabilitySlot[]>([])
  const [slotsLoading, setSlotsLoading] = useState(false)
  const [slotsError, setSlotsError] = useState<string | null>(null)
  const [selectedSlot, setSelectedSlot] = useState<PublicAvailabilitySlot | null>(null)
  const [refreshKey, setRefreshKey] = useState(0)

  const [name, setName] = useState('')
  const [phone, setPhone] = useState('')
  const [notes, setNotes] = useState('')
  const [errors, setErrors] = useState<FieldErrors>({})
  const [submitting, setSubmitting] = useState(false)
  const [bookingError, setBookingError] = useState<string | null>(null)
  const [confirmation, setConfirmation] = useState<PublicBookingResult | null>(null)
  const [includeReminders, setIncludeReminders] = useState(true)

  const [findPhone, setFindPhone] = useState('')
  const [findName, setFindName] = useState('')
  const [finding, setFinding] = useState(false)
  const [findError, setFindError] = useState<string | null>(null)
  const [foundAppointments, setFoundAppointments] = useState<
    import('../types/publicBooking').PublicFoundAppointment[]
  >([])

  const shop = shopData?.shop ?? null
  const services = shopData?.services ?? []
  const staffMembers = shopData?.staff ?? []
  const selectedService = services.find((service) => service.id === serviceId) ?? null
  const selectedStaff = staffMembers.find((member) => member.id === staffId) ?? null

  const today = useMemo(
    () => (shop ? shopDateKey(new Date(), shop.timezone) : ''),
    [shop],
  )
  const maxDate = useMemo(() => (today ? addDaysToDateKey(today, 90) : ''), [today])
  const days = useMemo(
    () => (today ? Array.from({ length: 7 }, (_, index) => addDaysToDateKey(today, index)) : []),
    [today],
  )

  useEffect(() => {
    if (!slug) {
      setShopData(null)
      setLoadError(null)
      setLoading(false)
      return
    }

    let cancelled = false
    setLoading(true)
    setLoadError(null)

    getPublicShop(slug)
      .then((payload) => {
        if (cancelled) return
        if (!payload) {
          setShopData(null)
          return
        }

        setShopData(payload)
        setDateKey(shopDateKey(new Date(), payload.shop.timezone))
        setServiceId(payload.services[0]?.id ?? '')
        setStaffId(payload.staff[0]?.id ?? '')
        setSelectedSlot(null)
      })
      .catch((error: unknown) => {
        if (!cancelled) {
          setLoadError(
            error instanceof Error ? error.message : 'No pudimos cargar el local.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [slug, reloadKey])

  useEffect(() => {
    if (!shopData || !serviceId || !staffId || !dateKey) {
      setSlots([])
      setSlotsLoading(false)
      setSlotsError(null)
      return
    }

    let cancelled = false
    setSlotsLoading(true)
    setSlotsError(null)

    listPublicAvailability(slug, serviceId, dateKey, staffId)
      .then((rows) => {
        if (cancelled) return
        setSlots(rows)
        setSelectedSlot((current) =>
          current &&
          rows.some(
            (row) =>
              row.staff_id === current.staff_id && row.slot_start === current.slot_start,
          )
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
  }, [shopData, slug, serviceId, staffId, dateKey, refreshKey])

  function chooseService(id: string) {
    setServiceId(id)
    setSelectedSlot(null)
    setErrors({})
    setBookingError(null)
  }

  function chooseStaff(id: string) {
    setStaffId(id)
    setSelectedSlot(null)
    setErrors({})
    setBookingError(null)
  }

  function chooseDate(nextDateKey: string) {
    setDateKey(nextDateKey)
    setSelectedSlot(null)
    setErrors({})
    setBookingError(null)
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (submitting) return

    const nextErrors: FieldErrors = {}
    const trimmedName = name.trim()
    const digits = normalizePhone(phone)

    if (trimmedName.length < 2 || trimmedName.length > 80) {
      nextErrors.name = 'El nombre debe tener entre 2 y 80 caracteres.'
    }
    if (digits.length < 8 || digits.length > 20) {
      nextErrors.phone = 'Ingresá un teléfono de 8 a 20 dígitos, con código de área.'
    }
    if (notes.trim().length > 500) {
      nextErrors.notes = 'Las notas no pueden superar los 500 caracteres.'
    }
    if (!selectedSlot) {
      nextErrors.slot = 'Elegí un horario disponible.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) {
      if (nextErrors.slot) {
        document.getElementById('public-slots')?.scrollIntoView({
          behavior: 'smooth',
          block: 'center',
        })
      }
      return
    }
    if (!selectedSlot) return

    setSubmitting(true)
    setBookingError(null)

    try {
      const result = await createPublicBooking({
        slug,
        serviceId,
        staffId,
        startsAt: selectedSlot.slot_start,
        clientName: trimmedName,
        clientPhone: digits,
        notes,
      })
      setConfirmation(result)
      window.scrollTo({ top: 0 })
    } catch (error) {
      const message =
        error instanceof Error ? error.message : 'No pudimos guardar la reserva.'
      setBookingError(message)
      if (
        error instanceof PublicBookingError &&
        (error.code === '23P01' || /horario/i.test(message))
      ) {
        setSelectedSlot(null)
        setRefreshKey((current) => current + 1)
      }
    } finally {
      setSubmitting(false)
    }
  }

  function resetBooking() {
    setConfirmation(null)
    setName('')
    setPhone('')
    setNotes('')
    setErrors({})
    setBookingError(null)
    setSelectedSlot(null)
    if (shop) setDateKey(shopDateKey(new Date(), shop.timezone))
    setRefreshKey((current) => current + 1)
    window.scrollTo({ top: 0 })
  }

  async function handleFindAppointments(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setFinding(true)
    setFindError(null)
    setFoundAppointments([])
    try {
      const rows = await findPublicAppointments(slug, findPhone, findName)
      setFoundAppointments(rows)
      if (rows.length === 0) {
        setFindError('No encontramos turnos con esos datos.')
      }
    } catch (error) {
      setFindError(
        error instanceof Error ? error.message : 'No pudimos buscar tus turnos.',
      )
    } finally {
      setFinding(false)
    }
  }

  if (loading) return <PublicLoading />

  if (!shopData || !shop) {
    if (loadError) {
      return (
        <NoticePage
          title="No pudimos abrir la reserva"
          message={loadError}
          onRetry={() => setReloadKey((current) => current + 1)}
        />
      )
    }
    return (
      <NoticePage
        title="Link no disponible"
        message="Pedile al local un link actualizado para reservar tu turno."
      />
    )
  }

  if (confirmation) {
    const confirmedDate = dateKeyLongLabel(
      shopDateKey(new Date(confirmation.starts_at), shop.timezone),
    )
    const confirmedStart = zonedTime(confirmation.starts_at, shop.timezone)
    const confirmedEnd = zonedTime(confirmation.ends_at, shop.timezone)

    return (
      <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center px-5 py-10">
        <section className="rounded-xl border border-base bg-surface p-5 sm:p-6">
          <span className="inline-flex size-11 items-center justify-center rounded-xl bg-income-soft text-income">
            <CheckCircle2 size={24} aria-hidden="true" />
          </span>
          <h1 className="mt-4 text-xl font-bold leading-tight">Reserva recibida</h1>
          <p className="mt-1 text-sm text-muted">Te esperamos en {shop.name}.</p>

          <dl className="mt-4 space-y-2 rounded-xl border border-base bg-surface-alt/60 p-3 text-sm">
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-xs text-muted">Servicio</dt>
              <dd className="text-right font-semibold">{confirmation.service_name}</dd>
            </div>
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-xs text-muted">Profesional</dt>
              <dd className="text-right font-medium">{confirmation.staff_name}</dd>
            </div>
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-xs text-muted">Fecha</dt>
              <dd className="text-right font-medium">{confirmedDate}</dd>
            </div>
            <div className="flex items-baseline justify-between gap-3">
              <dt className="text-xs text-muted">Horario</dt>
              <dd className="numeric text-right font-semibold">
                {confirmedStart}–{confirmedEnd}
              </dd>
            </div>
          </dl>

          <p className="mt-3 rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending">
            Tu turno queda pendiente hasta que el local lo confirme.
          </p>

          {(shop.address || shop.phone) && (
            <div className="mt-3 space-y-1.5 text-xs text-muted">
              {shop.address && (
                <p className="flex items-start gap-1.5">
                  <MapPin size={13} className="mt-0.5 shrink-0" aria-hidden="true" />
                  {shop.address}
                </p>
              )}
              {shop.phone && (
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

          <div className="mt-4 space-y-2">
            <label className="flex items-center gap-2 text-xs text-muted">
              <input
                type="checkbox"
                checked={includeReminders}
                onChange={(event) => setIncludeReminders(event.target.checked)}
                className="size-4 rounded border-base"
              />
              Recordarme 1 día antes y 2 horas antes
            </label>
            <div className="flex flex-col gap-2">
              <button
                type="button"
                onClick={() => downloadCalendar(confirmation, shop, includeReminders)}
                className="inline-flex min-h-[44px] items-center justify-center gap-2 rounded-lg border border-base bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-alt"
              >
                Guardar en calendario
              </button>
              <a
                href={`https://wa.me/?text=${encodeURIComponent(
                  `Mi turno en ${shop.name}: ${confirmation.service_name} con ${confirmation.staff_name}, ${confirmedDate} ${confirmedStart}–${confirmedEnd}. Gestionar: ${window.location.origin}/turno/${confirmation.public_token}`,
                )}`}
                target="_blank"
                rel="noreferrer"
                className="inline-flex min-h-[44px] items-center justify-center gap-2 rounded-lg border border-base bg-surface px-4 text-sm font-semibold text-ink hover:bg-surface-alt"
              >
                Enviar por WhatsApp
              </a>
              {confirmation.public_token && (
                <a
                  href={`/turno/${confirmation.public_token}`}
                  className="inline-flex min-h-[44px] items-center justify-center rounded-lg border border-strong bg-brand-primary px-4 text-sm font-semibold text-white"
                >
                  Gestionar mi turno
                </a>
              )}
              <Button type="button" variant="secondary" onClick={resetBooking}>
                Hacer otra reserva
              </Button>
            </div>
          </div>
          {confirmation.public_token && (
            <p className="mt-2 text-center text-[11px] text-muted">
              Guardá este link para cancelar o cambiar el horario sin llamar.
            </p>
          )}
        </section>

        <p className="mt-5 text-center text-[11px] text-muted">
          Reserva gestionada con ANSTUDIOS
        </p>
      </main>
    )
  }

  if (services.length === 0 || staffMembers.length === 0) {
    return (
      <main className="mx-auto w-full max-w-lg px-5 pb-16 pt-8">
        <ShopHeader shop={shop} />
        <section className="mt-5 rounded-xl border border-base bg-surface p-4 sm:p-5">
          <h2 className="text-base font-semibold">Reservas online cerradas por ahora</h2>
          <p className="mt-1 text-sm text-muted">
            Este local todavía no tiene{' '}
            {services.length === 0 ? 'servicios disponibles' : 'profesionales disponibles'} para
            reservar online.
          </p>
          {shop.phone && (
            <a
              href={`tel:${shop.phone.replace(/[^\d+]/g, '')}`}
              className="mt-3 inline-flex min-h-[44px] items-center gap-2 text-sm font-semibold text-ink underline decoration-base underline-offset-4 hover:decoration-strong"
            >
              <Phone size={16} aria-hidden="true" />
              Llamar al local
            </a>
          )}
        </section>
      </main>
    )
  }

  return (
    <main className="mx-auto w-full max-w-lg px-5 pb-16 pt-8">
      <ShopHeader shop={shop} />

      <section className="mt-5 rounded-xl border border-base bg-surface p-4 sm:p-5">
        <h2 className="text-sm font-semibold">¿Ya tenés un turno?</h2>
        <p className="mt-1 text-xs text-muted">
          Buscalo con tu teléfono o nombre para modificarlo o cancelarlo.
        </p>
        <form onSubmit={handleFindAppointments} className="mt-3 space-y-3" noValidate>
          <div className="space-y-1.5">
            <label htmlFor="find-phone" className="text-xs font-medium text-muted">
              Teléfono
            </label>
            <Input
              id="find-phone"
              type="tel"
              value={findPhone}
              onChange={(event) => setFindPhone(event.target.value)}
              placeholder="11 5555 5555"
            />
          </div>
          <div className="space-y-1.5">
            <label htmlFor="find-name" className="text-xs font-medium text-muted">
              Nombre y apellido
            </label>
            <Input
              id="find-name"
              value={findName}
              onChange={(event) => setFindName(event.target.value)}
              placeholder="Martina López"
            />
          </div>
          <Button type="submit" loading={finding}>
            Buscar mi turno
          </Button>
          {findError && (
            <p role="alert" className="text-xs font-medium text-expense">{findError}</p>
          )}
        </form>

        {foundAppointments.length > 0 && (
          <ul className="mt-3 space-y-2">
            {foundAppointments.map((item) => (
              <li key={item.appointment_id}>
                <a
                  href={`/turno/${item.public_token}`}
                  className="flex min-h-[44px] items-center justify-between gap-2 rounded-lg border border-base bg-surface-alt/60 px-3 py-2 text-sm hover:border-strong"
                >
                  <span className="min-w-0">
                    <span className="block font-semibold">{item.service_name ?? 'Turno'}</span>
                    <span className="numeric block text-xs text-muted">
                      {new Date(item.starts_at).toLocaleString('es-AR', {
                        dateStyle: 'short',
                        timeStyle: 'short',
                      })}
                    </span>
                  </span>
                  <span className="text-xs font-semibold text-ink">Gestionar →</span>
                </a>
              </li>
            ))}
          </ul>
        )}
      </section>

      <div className="mt-5 space-y-3">
        <Step index="01" title="Elegí un servicio">
          <div className="space-y-2" role="group" aria-label="Servicio">
            {services.map((service) => {
              const active = service.id === serviceId
              return (
                <button
                  key={service.id}
                  type="button"
                  aria-pressed={active}
                  onClick={() => chooseService(service.id)}
                  className={`flex min-h-[56px] w-full items-center justify-between gap-3 rounded-lg border p-3 text-left transition-colors ${
                    active
                      ? 'border-strong bg-surface-alt'
                      : 'border-base bg-surface hover:border-strong'
                  }`}
                >
                  <span className="min-w-0">
                    <span className="block text-sm font-semibold">{service.name}</span>
                    <span className="numeric mt-0.5 block text-xs text-muted">
                      {service.duration_min} min
                    </span>
                  </span>
                  <span className="flex shrink-0 items-center gap-2">
                    <span className="numeric text-sm font-semibold">
                      {formatMoney(Number(service.price))}
                    </span>
                    {active && <Check size={16} aria-hidden="true" />}
                  </span>
                </button>
              )
            })}
          </div>
        </Step>

        <Step index="02" title="Elegí un profesional">
          <div className="grid grid-cols-2 gap-2" role="group" aria-label="Profesional">
            {staffMembers.map((member) => {
              const active = member.id === staffId
              return (
                <button
                  key={member.id}
                  type="button"
                  aria-pressed={active}
                  onClick={() => chooseStaff(member.id)}
                  className={`flex min-h-[44px] items-center gap-2 rounded-lg border px-3 text-left text-sm font-medium transition-colors ${
                    active
                      ? 'border-strong bg-surface-alt'
                      : 'border-base bg-surface hover:border-strong'
                  }`}
                >
                  {member.photo_url ? (
                    <img
                      src={member.photo_url}
                      alt=""
                      className="size-7 shrink-0 rounded-full border border-base object-cover"
                    />
                  ) : (
                    <span
                      aria-hidden="true"
                      className="size-2.5 shrink-0 rounded-full border border-strong/20"
                      style={{ backgroundColor: member.color_hex }}
                    />
                  )}
                  <span className="truncate">{member.name}</span>
                  {active && <Check size={14} className="ml-auto shrink-0" aria-hidden="true" />}
                </button>
              )
            })}
          </div>
          {selectedStaff?.bio && (
            <p className="mt-2 text-xs text-muted">{selectedStaff.bio}</p>
          )}
        </Step>

        <Step index="03" title="Elegí fecha y horario">
          <div className="-mx-1 flex gap-1.5 overflow-x-auto px-1 pb-1">
            {days.map((day, index) => {
              const active = day === dateKey
              return (
                <button
                  key={day}
                  type="button"
                  aria-pressed={active}
                  aria-label={dateKeyLongLabel(day)}
                  onClick={() => chooseDate(day)}
                  className={`flex min-h-[58px] min-w-[56px] shrink-0 flex-col items-center justify-center rounded-lg border px-2 transition-colors ${
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
                    {dayNumber(day)}
                  </span>
                </button>
              )
            })}
          </div>

          <div className="mt-3 space-y-1.5">
            <label htmlFor="public-date" className="text-xs font-medium text-muted">
              Otra fecha
            </label>
            <Input
              id="public-date"
              type="date"
              min={today}
              max={maxDate}
              value={dateKey}
              onChange={(event) => {
                if (event.target.value) chooseDate(event.target.value)
              }}
              className="numeric"
            />
          </div>

          <div id="public-slots" className="mt-4">
            <div className="flex items-center justify-between gap-2">
              <span className="text-xs font-medium text-muted">Horarios disponibles</span>
              {!slotsLoading && !slotsError && slots.length > 0 && (
                <span className="numeric text-[11px] text-muted">
                  {slots.length} {slots.length === 1 ? 'horario' : 'horarios'}
                </span>
              )}
            </div>

            <div className="mt-2">
              {slotsLoading && (
                <p className="flex min-h-[44px] items-center gap-2 text-sm text-muted">
                  <Loader2 size={16} className="animate-spin" aria-hidden="true" />
                  Verificando disponibilidad…
                </p>
              )}

              {!slotsLoading && slotsError && (
                <div className="rounded-lg border border-base bg-surface-alt/60 px-3 py-2.5">
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
                <p className="rounded-lg border border-base bg-surface-alt/60 px-3 py-2.5 text-xs text-muted">
                  No quedan horarios libres ese día
                  {selectedStaff ? ` con ${selectedStaff.name}` : ''}. Probá otra fecha.
                </p>
              )}

              {!slotsLoading && !slotsError && slots.length > 0 && (
                <div
                  className="grid grid-cols-4 gap-1.5"
                  role="group"
                  aria-label="Horarios disponibles"
                >
                  {slots.map((slot) => {
                    const time = zonedTime(slot.slot_start, shop.timezone)
                    const active = selectedSlot?.slot_start === slot.slot_start
                    return (
                      <button
                        key={slot.slot_start}
                        type="button"
                        aria-pressed={active}
                        onClick={() => {
                          setSelectedSlot(slot)
                          setErrors((current) => ({ ...current, slot: undefined }))
                          setBookingError(null)
                        }}
                        className={`numeric min-h-[44px] rounded-lg border text-xs font-semibold transition-colors ${
                          active
                            ? 'border-strong bg-brand-primary text-white'
                            : 'border-base bg-surface text-ink hover:border-strong'
                        }`}
                      >
                        {time}
                      </button>
                    )
                  })}
                </div>
              )}
            </div>

            <FieldError>{errors.slot ?? null}</FieldError>
          </div>
        </Step>

        <Step index="04" title="Tus datos">
          <form onSubmit={handleSubmit} className="space-y-4" noValidate>
            <div className="rounded-lg border border-base bg-surface-alt/60 p-3">
              <p className="text-xs font-semibold text-muted">Tu reserva</p>
              {selectedSlot && selectedService && selectedStaff ? (
                <>
                  <p className="mt-1 text-sm font-semibold">
                    {selectedService.name} · {selectedStaff.name}
                  </p>
                  <p className="numeric mt-0.5 text-xs text-muted">
                    {dateKeyLongLabel(
                      shopDateKey(new Date(selectedSlot.slot_start), shop.timezone),
                    )}{' '}
                    · {zonedTime(selectedSlot.slot_start, shop.timezone)} hs
                  </p>
                </>
              ) : (
                <p className="mt-1 text-xs text-muted">
                  Elegí un horario arriba para confirmar la reserva.
                </p>
              )}
            </div>

            <div className="space-y-1.5">
              <label htmlFor="public-name" className="text-sm font-medium">
                Nombre y apellido
              </label>
              <Input
                id="public-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                maxLength={80}
                autoComplete="name"
                placeholder="Martina López"
                aria-invalid={Boolean(errors.name)}
              />
              <FieldError>{errors.name ?? null}</FieldError>
            </div>

            <div className="space-y-1.5">
              <label htmlFor="public-phone" className="text-sm font-medium">
                Teléfono
              </label>
              <Input
                id="public-phone"
                type="tel"
                inputMode="tel"
                value={phone}
                onChange={(event) => setPhone(event.target.value)}
                placeholder="11 5555 5555"
                autoComplete="tel"
                aria-invalid={Boolean(errors.phone)}
              />
              <p className="text-xs text-muted">
                Con código de área. Lo usamos para avisarte del turno.
              </p>
              <FieldError>{errors.phone ?? null}</FieldError>
            </div>

            <div className="space-y-1.5">
              <label htmlFor="public-notes" className="text-sm font-medium">
                Notas <span className="font-normal text-muted">(opcional)</span>
              </label>
              <Textarea
                id="public-notes"
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
                maxLength={500}
                placeholder="Alguna indicación para tu turno…"
              />
              <span className="numeric block text-right text-[11px] text-muted">
                {notes.length}/500
              </span>
              <FieldError>{errors.notes ?? null}</FieldError>
            </div>

            {bookingError && (
              <p
                role="alert"
                className="rounded-lg border border-expense/30 bg-expense-soft px-3 py-2 text-xs font-medium text-expense"
              >
                {bookingError}
              </p>
            )}

            <Button type="submit" loading={submitting}>
              Confirmar reserva
            </Button>
            <p className="text-center text-[11px] text-muted">
              Tus datos se usan solo para gestionar este turno.
            </p>
          </form>
        </Step>
      </div>

      <p className="mt-6 text-center text-[11px] text-muted">
        Reserva gestionada con ANSTUDIOS
      </p>
    </main>
  )
}

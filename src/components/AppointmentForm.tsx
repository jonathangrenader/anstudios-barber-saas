import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Loader2, Search, X } from 'lucide-react'
import { createAppointment, listAppointmentsForDay } from '../lib/appointments'
import { createClient, findClientByPhone, listClients, normalizePhone } from '../lib/clients'
import { useOnlineStatus } from '../hooks/useOnlineStatus'
import {
  buildDaySlots,
  timeToMinutes,
  zonedDayRange,
  zonedTime,
  zonedTimeToUtc,
} from '../lib/datetime'
import type { CatalogItem } from '../types/catalog'
import type { Client } from '../types/client'
import type { Shop } from '../types/shop'
import type { StaffMember } from '../types/staff'
import type { AppointmentView } from '../types/appointment'
import { Button, Checkbox, FieldError, Input, Select, Textarea } from './ui/controls'

type FieldErrors = Partial<
  Record<'clientName' | 'clientPhone' | 'service' | 'staff' | 'time', string>
>

const ACTIVE_STATUSES = ['pending', 'confirmed', 'in_progress']

function fold(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
}

export function AppointmentForm({
  shop,
  staff,
  services,
  dateKey: initialDateKey,
  initialStaffId,
  onSaved,
  onCancel,
}: {
  shop: Shop
  staff: StaffMember[]
  services: CatalogItem[]
  dateKey: string
  initialStaffId?: string
  onSaved: (message?: string) => void
  onCancel: () => void
}) {
  const online = useOnlineStatus()
  const [dateKey, setDateKey] = useState(initialDateKey)
  const [staffId, setStaffId] = useState(initialStaffId ?? staff[0]?.id ?? '')
  const [serviceId, setServiceId] = useState(services[0]?.id ?? '')
  const [time, setTime] = useState<string | null>(null)
  const [status, setStatus] = useState<'pending' | 'confirmed'>('confirmed')
  const [walkIn, setWalkIn] = useState(false)
  const [notes, setNotes] = useState('')

  const [clients, setClients] = useState<Client[]>([])
  const [clientsLoading, setClientsLoading] = useState(true)
  const [clientsError, setClientsError] = useState<string | null>(null)
  const [mode, setMode] = useState<'existing' | 'new'>('existing')
  const [clientQuery, setClientQuery] = useState('')
  const [showAllClientResults, setShowAllClientResults] = useState(false)
  const [selectedClient, setSelectedClient] = useState<Client | null>(null)
  const [newName, setNewName] = useState('')
  const [newPhone, setNewPhone] = useState('')

  const [busy, setBusy] = useState<AppointmentView[]>([])
  const [busyLoading, setBusyLoading] = useState(true)
  const [busyError, setBusyError] = useState<string | null>(null)

  const [errors, setErrors] = useState<FieldErrors>({})
  const [pending, setPending] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  const service = services.find((item) => item.id === serviceId) ?? null
  const durationMin = service?.duration_min ?? shop.slot_duration_min

  useEffect(() => {
    let cancelled = false
    setClientsLoading(true)
    setClientsError(null)

    listClients(shop.id)
      .then((rows) => {
        if (cancelled) return
        setClients(rows)
        if (rows.length === 0) setMode('new')
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setClientsError(
            err instanceof Error ? err.message : 'No pudimos cargar los clientes.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setClientsLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [shop.id])

  useEffect(() => {
    let cancelled = false
    const { start, end } = zonedDayRange(dateKey, shop.timezone)
    setBusyLoading(true)
    setBusyError(null)

    listAppointmentsForDay(shop.id, start.toISOString(), end.toISOString())
      .then((rows) => {
        if (!cancelled) setBusy(rows)
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setBusyError(
            err instanceof Error ? err.message : 'No pudimos verificar la disponibilidad.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setBusyLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [shop.id, shop.timezone, dateKey])

  const slots = useMemo(() => {
    const busyBlocks = busy
      .filter(
        (appointment) =>
          appointment.staff_id === staffId && ACTIVE_STATUSES.includes(appointment.status),
      )
      .map((appointment) => ({
        start: timeToMinutes(zonedTime(appointment.starts_at, shop.timezone)),
        end: timeToMinutes(zonedTime(appointment.ends_at, shop.timezone)),
      }))

    return buildDaySlots({
      openTime: shop.open_time,
      closeTime: shop.close_time,
      stepMin: shop.slot_duration_min,
      durationMin,
      busy: busyBlocks,
    })
  }, [busy, staffId, shop.timezone, shop.open_time, shop.close_time, shop.slot_duration_min, durationMin])

  const slotsKey = slots.map((slot) => `${slot.time}:${slot.available ? 1 : 0}`).join('|')

  useEffect(() => {
    if (!time) return
    const current = slots.find((slot) => slot.time === time)
    if (!current?.available) setTime(null)
    // `slotsKey` resume la grilla para no depender de un array nuevo en cada render.
  }, [slots, slotsKey, time])

  const search = fold(clientQuery.trim())
  const digits = search.replace(/\D/g, '')
  const clientResults = search
    ? clients
        .filter(
          (client) =>
            fold(client.full_name).includes(search) ||
            (digits.length > 0 && client.phone.includes(digits)),
        )
        .slice(0, 12)
    : clients.slice(0, 12)

  useEffect(() => {
    setShowAllClientResults(false)
  }, [clientQuery])

  const CLIENT_PREVIEW_COUNT = 4
  const visibleClientResults = showAllClientResults
    ? clientResults
    : clientResults.slice(0, CLIENT_PREVIEW_COUNT)

  async function resolveClient(): Promise<{ id: string; name: string; phone: string }> {
    if (mode === 'existing') {
      if (!selectedClient) throw new Error('Elegí un cliente o cargá uno nuevo.')
      return {
        id: selectedClient.id,
        name: selectedClient.full_name,
        phone: selectedClient.phone,
      }
    }

    const phone = normalizePhone(newPhone)
    try {
      const created = await createClient(shop.id, {
        full_name: newName.trim(),
        phone,
        technical_notes: null,
      })
      return { id: created.id, name: created.full_name, phone: created.phone }
    } catch (err) {
      // Si el teléfono ya existe, reutilizamos esa ficha en lugar de bloquear la reserva.
      const existing = await findClientByPhone(shop.id, phone)
      if (existing) return { id: existing.id, name: existing.full_name, phone: existing.phone }
      throw err
    }
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    if (mode === 'new') {
      const name = newName.trim()
      const phone = normalizePhone(newPhone)
      if (name.length < 2 || name.length > 80) {
        nextErrors.clientName = 'El nombre debe tener entre 2 y 80 caracteres.'
      }
      if (phone.length < 8 || phone.length > 20) {
        nextErrors.clientPhone = 'Ingresá un teléfono de 8 a 20 dígitos.'
      }
    } else if (!selectedClient) {
      nextErrors.clientName = 'Elegí un cliente o cargá uno nuevo.'
    }

    if (!serviceId) nextErrors.service = 'Elegí un servicio.'
    if (!staffId) nextErrors.staff = 'Elegí un profesional.'
    if (!time) nextErrors.time = 'Elegí un horario disponible.'

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    setPending(true)
    setSubmitError(null)
    try {
      const client = await resolveClient()
      const startsAt = zonedTimeToUtc(dateKey, time as string, shop.timezone)
      const endsAt = new Date(startsAt.getTime() + durationMin * 60_000)

      const result = await createAppointment(shop.id, {
        client_id: client.id,
        staff_id: staffId,
        service_id: serviceId || null,
        client_name_snapshot: client.name,
        client_phone_snapshot: client.phone,
        starts_at: startsAt.toISOString(),
        ends_at: endsAt.toISOString(),
        status,
        source: walkIn ? 'walk_in' : 'admin',
        notes: notes.trim() || null,
      })
      onSaved(
        result.queued
          ? 'Turno guardado sin conexión. Se sincronizará al reconectar.'
          : undefined,
      )
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'No pudimos crear el turno.')
    } finally {
      setPending(false)
    }
  }

  if (services.length === 0) {
    return (
      <div className="space-y-4">
        <p className="text-sm">
          Necesitás al menos un servicio activo para agendar un turno.
        </p>
        <p className="text-xs text-muted">Cargalo desde la pestaña Catálogo.</p>
        <Button type="button" variant="secondary" onClick={onCancel}>
          Cerrar
        </Button>
      </div>
    )
  }

  if (staff.length === 0) {
    return (
      <div className="space-y-4">
        <p className="text-sm">
          Necesitás al menos un profesional activo para agendar un turno.
        </p>
        <p className="text-xs text-muted">Agregalo desde la pestaña Equipo.</p>
        <Button type="button" variant="secondary" onClick={onCancel}>
          Cerrar
        </Button>
      </div>
    )
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      {!online && (
        <p className="rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending">
          Sin conexión: la disponibilidad es la última guardada. El turno y, si hace
          falta, el cliente nuevo se sincronizarán al reconectar.
        </p>
      )}

      <div className="space-y-1.5">
        <label htmlFor="appt-date" className="text-sm font-medium">
          Fecha
        </label>
        <Input
          id="appt-date"
          type="date"
          value={dateKey}
          onChange={(event) => {
            if (event.target.value) setDateKey(event.target.value)
          }}
        />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="appt-service" className="text-sm font-medium">
            Servicio
          </label>
          <Select
            id="appt-service"
            value={serviceId}
            onChange={(event) => {
              setServiceId(event.target.value)
              setTime(null)
            }}
            aria-invalid={Boolean(errors.service)}
          >
            {services.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} · {item.duration_min} min
              </option>
            ))}
          </Select>
          <FieldError>{errors.service ?? null}</FieldError>
        </div>

        <div className="space-y-1.5">
          <label htmlFor="appt-staff" className="text-sm font-medium">
            Profesional
          </label>
          <Select
            id="appt-staff"
            value={staffId}
            onChange={(event) => {
              setStaffId(event.target.value)
              setTime(null)
            }}
            aria-invalid={Boolean(errors.staff)}
          >
            {staff.map((member) => (
              <option key={member.id} value={member.id}>
                {member.name}
              </option>
            ))}
          </Select>
          <FieldError>{errors.staff ?? null}</FieldError>
        </div>
      </div>

      <div className="space-y-2">
        <div className="flex items-center justify-between gap-2">
          <span className="text-sm font-medium">Cliente</span>
          <div className="grid grid-cols-2 gap-1 rounded-lg border border-base bg-surface-alt p-1">
            <button
              type="button"
              onClick={() => setMode('existing')}
              aria-pressed={mode === 'existing'}
              className={`min-h-[44px] rounded-md px-2 text-xs font-semibold ${
                mode === 'existing' ? 'border border-strong bg-surface text-ink' : 'text-muted'
              }`}
            >
              Existente
            </button>
            <button
              type="button"
              onClick={() => setMode('new')}
              aria-pressed={mode === 'new'}
              className={`min-h-[44px] rounded-md px-2 text-xs font-semibold ${
                mode === 'new' ? 'border border-strong bg-surface text-ink' : 'text-muted'
              }`}
            >
              Nuevo
            </button>
          </div>
        </div>

        {mode === 'existing' && (
          <div>
            {selectedClient ? (
              <div className="flex items-center justify-between gap-2 rounded-lg border border-strong bg-surface px-3 py-2">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold">{selectedClient.full_name}</p>
                  <p className="numeric text-xs text-muted">{selectedClient.phone}</p>
                </div>
                <button
                  type="button"
                  onClick={() => setSelectedClient(null)}
                  aria-label="Quitar cliente seleccionado"
                  className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
                >
                  <X size={16} aria-hidden="true" />
                </button>
              </div>
            ) : (
              <>
                <div className="relative">
                  <Search
                    size={16}
                    aria-hidden="true"
                    className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted"
                  />
                  <Input
                    type="search"
                    value={clientQuery}
                    onChange={(event) => setClientQuery(event.target.value)}
                    placeholder="Buscar por nombre o teléfono…"
                    aria-label="Buscar cliente"
                    className="pl-9"
                  />
                </div>

                {clientsLoading && <p className="mt-2 text-xs text-muted">Cargando clientes…</p>}
                <FieldError>{clientsError}</FieldError>

                {!clientsLoading && clientResults.length > 0 && (
                  <>
                    <ul className="mt-2 max-h-44 overflow-y-auto rounded-lg border border-base">
                    {visibleClientResults.map((client) => (
                      <li key={client.id}>
                        <button
                          type="button"
                          onClick={() => {
                            setSelectedClient(client)
                            setClientQuery('')
                          }}
                          className="flex min-h-[44px] w-full items-center justify-between gap-2 border-b border-base px-3 text-left last:border-b-0 hover:bg-surface-alt"
                        >
                          <span className="truncate text-sm">{client.full_name}</span>
                          <span className="numeric shrink-0 text-xs text-muted">{client.phone}</span>
                        </button>
                      </li>
                    ))}
                    </ul>
                    {clientResults.length > CLIENT_PREVIEW_COUNT && (
                      <button
                        type="button"
                        onClick={() => setShowAllClientResults((current) => !current)}
                        className="mt-2 min-h-[44px] w-full rounded-lg border border-base px-3 text-xs font-semibold text-muted hover:bg-surface-alt hover:text-ink"
                      >
                        {showAllClientResults
                          ? 'Mostrar menos'
                          : `Ver ${clientResults.length - CLIENT_PREVIEW_COUNT} más`}
                      </button>
                    )}
                  </>
                )}

                {!clientsLoading && clientResults.length === 0 && (
                  <p className="mt-2 text-xs text-muted">
                    Sin resultados.{' '}
                    <button
                      type="button"
                      onClick={() => setMode('new')}
                      className="font-semibold text-ink underline underline-offset-4"
                    >
                      Cargar cliente nuevo
                    </button>
                  </p>
                )}

                <FieldError>{errors.clientName ?? null}</FieldError>
              </>
            )}
          </div>
        )}

        {mode === 'new' && (
          <div className="space-y-3 rounded-lg border border-base bg-surface-alt/50 p-3">
            <div className="space-y-1.5">
              <label htmlFor="appt-client-name" className="text-sm font-medium">
                Nombre completo
              </label>
              <Input
                id="appt-client-name"
                value={newName}
                onChange={(event) => setNewName(event.target.value)}
                placeholder="Martina López"
                autoComplete="off"
                aria-invalid={Boolean(errors.clientName)}
              />
              <FieldError>{errors.clientName ?? null}</FieldError>
            </div>
            <div className="space-y-1.5">
              <label htmlFor="appt-client-phone" className="text-sm font-medium">
                Teléfono
              </label>
              <Input
                id="appt-client-phone"
                type="tel"
                inputMode="tel"
                value={newPhone}
                onChange={(event) => setNewPhone(event.target.value)}
                placeholder="11 5555 5555"
                autoComplete="off"
                aria-invalid={Boolean(errors.clientPhone)}
              />
              <p className="text-xs text-muted">Solo números, con código de área.</p>
              <FieldError>{errors.clientPhone ?? null}</FieldError>
            </div>
          </div>
        )}
      </div>

      <div className="space-y-1.5">
        <span className="text-sm font-medium">Horario</span>

        {busyLoading && (
          <p className="flex min-h-[44px] items-center gap-2 text-sm text-muted">
            <Loader2 size={16} className="animate-spin" aria-hidden="true" />
            Verificando disponibilidad…
          </p>
        )}
        <FieldError>{busyError}</FieldError>

        {!busyLoading && !busyError && slots.length === 0 && (
          <p className="text-xs text-muted">
            La duración del servicio no entra en el horario del local.
          </p>
        )}

        {!busyLoading && slots.length > 0 && (
          <div className="grid grid-cols-4 gap-1.5" role="group" aria-label="Horarios disponibles">
            {slots.map((slot) => {
              const selected = slot.time === time
              return (
                <button
                  key={slot.time}
                  type="button"
                  disabled={!slot.available}
                  onClick={() => setTime(slot.time)}
                  aria-pressed={selected}
                  aria-label={`${slot.time}${slot.available ? '' : ' ocupado'}`}
                  className={`numeric min-h-[44px] rounded-lg border text-xs font-semibold transition-colors ${
                    selected
                      ? 'border-strong bg-brand-primary text-white'
                      : slot.available
                        ? 'border-base bg-surface text-ink hover:border-strong'
                        : 'cursor-not-allowed border-base bg-surface-alt text-muted/50 line-through'
                  }`}
                >
                  {slot.time}
                </button>
              )
            })}
          </div>
        )}
        <FieldError>{errors.time ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="appt-notes" className="text-sm font-medium">
          Notas <span className="font-normal text-muted">(opcional)</span>
        </label>
        <Textarea
          id="appt-notes"
          value={notes}
          onChange={(event) => setNotes(event.target.value)}
          maxLength={500}
          placeholder="Indicaciones para el turno…"
        />
        <span className="numeric block text-right text-[11px] text-muted">
          {notes.length}/500
        </span>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="appt-status" className="text-sm font-medium">
          Estado inicial
        </label>
        <Select
          id="appt-status"
          value={status}
          onChange={(event) => setStatus(event.target.value as 'pending' | 'confirmed')}
        >
          <option value="confirmed">Confirmado</option>
          <option value="pending">Pendiente</option>
        </Select>
      </div>

      <Checkbox
        label="Turno al paso (cliente sin reserva previa)"
        checked={walkIn}
        onChange={(event) => setWalkIn(event.target.checked)}
      />

      <FieldError>{submitError}</FieldError>

      <div className="space-y-2 pt-1">
        <Button type="submit" loading={pending}>
          Crear turno
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

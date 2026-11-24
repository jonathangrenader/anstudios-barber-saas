import { addDays } from 'date-fns'

/**
 * Utilidades de fecha/hora con zona del local sin dependencias extra.
 * Todo cálculo de "día" usa `shops.timezone`, no la zona del dispositivo.
 */

function datePartsInZone(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(date)

  const get = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === type)?.value ?? '0')

  return {
    year: get('year'),
    month: get('month'),
    day: get('day'),
    hour: get('hour'),
    minute: get('minute'),
    second: get('second'),
  }
}

function offsetMs(date: Date, timeZone: string): number {
  const p = datePartsInZone(date, timeZone)
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second)
  const floored = Math.floor(date.getTime() / 1000) * 1000
  return asUtc - floored
}

/** "2026-11-22" correspondiente a `date` en la zona del local. */
export function shopDateKey(date: Date, timeZone: string): string {
  const p = datePartsInZone(date, timeZone)
  return `${p.year}-${String(p.month).padStart(2, '0')}-${String(p.day).padStart(2, '0')}`
}

/** Hora local del local ("09:30") para un ISO UTC. */
export function zonedTime(iso: string, timeZone: string): string {
  const p = datePartsInZone(new Date(iso), timeZone)
  return `${String(p.hour).padStart(2, '0')}:${String(p.minute).padStart(2, '0')}`
}

/** Fecha corta local ("22 nov 2026") para un ISO UTC. */
export function zonedDateLabel(iso: string, timeZone: string): string {
  return new Intl.DateTimeFormat('es-AR', {
    timeZone,
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(new Date(iso))
}

/** Convierte fecha+hora de pared del local a un Date UTC. */
export function zonedTimeToUtc(dateKey: string, time: string, timeZone: string): Date {
  const [year, month, day] = dateKey.split('-').map(Number)
  const [hour, minute] = time.split(':').map(Number)
  const wallAsUtc = Date.UTC(year, month - 1, day, hour, minute)

  let timestamp = wallAsUtc - offsetMs(new Date(wallAsUtc), timeZone)
  // Segundo ajuste por si el primero cayó del otro lado de un cambio de horario.
  timestamp = wallAsUtc - offsetMs(new Date(timestamp), timeZone)
  return new Date(timestamp)
}

/** Rango [inicio, fin) del día local en UTC. */
export function zonedDayRange(dateKey: string, timeZone: string) {
  return {
    start: zonedTimeToUtc(dateKey, '00:00', timeZone),
    end: zonedTimeToUtc(addDaysToDateKey(dateKey, 1), '00:00', timeZone),
  }
}

export function addDaysToDateKey(dateKey: string, days: number): string {
  const base = new Date(`${dateKey}T12:00:00Z`)
  return addDays(base, days).toISOString().slice(0, 10)
}

/** "Sábado 22 de noviembre" en la zona del local. */
export function dateKeyLongLabel(dateKey: string): string {
  const label = new Intl.DateTimeFormat('es-AR', {
    timeZone: 'UTC',
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  }).format(new Date(`${dateKey}T12:00:00Z`))
  return label.charAt(0).toUpperCase() + label.slice(1)
}

export function dateKeyShortLabel(dateKey: string): string {
  return new Intl.DateTimeFormat('es-AR', {
    timeZone: 'UTC',
    weekday: 'short',
    day: 'numeric',
    month: 'short',
  }).format(new Date(`${dateKey}T12:00:00Z`))
}

export function isTodayInShop(timeZone: string): string {
  return shopDateKey(new Date(), timeZone)
}

export function timeToMinutes(time: string): number {
  const [hour, minute] = time.split(':').map(Number)
  return hour * 60 + minute
}

export function minutesToTime(minutes: number): string {
  const hour = Math.floor(minutes / 60)
  const minute = minutes % 60
  return `${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`
}

export type DaySlot = { time: string; available: boolean }

/** Grilla de horarios del local que admite la duración del servicio. */
export function buildDaySlots({
  openTime,
  closeTime,
  stepMin,
  durationMin,
  busy,
}: {
  openTime: string
  closeTime: string
  stepMin: number
  durationMin: number
  busy: { start: number; end: number }[]
}): DaySlot[] {
  const open = timeToMinutes(openTime)
  const close = timeToMinutes(closeTime)
  const step = Math.max(5, stepMin)
  const duration = Math.max(5, durationMin)
  const slots: DaySlot[] = []

  for (let start = open; start + duration <= close; start += step) {
    const available = !busy.some((block) => start < block.end && start + duration > block.start)
    slots.push({ time: minutesToTime(start), available })
  }

  return slots
}

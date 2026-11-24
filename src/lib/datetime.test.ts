import { describe, expect, it } from 'vitest'
import {
  addDaysToDateKey,
  buildDaySlots,
  minutesToTime,
  shopDateKey,
  timeToMinutes,
  zonedDayRange,
  zonedTime,
  zonedTimeToUtc,
} from './datetime'

const BA = 'America/Argentina/Buenos_Aires'

describe('shopDateKey', () => {
  it('usa el día del local, no el UTC', () => {
    // 02:30 UTC del 23 es 23:30 del 22 en Buenos Aires (UTC-3).
    expect(shopDateKey(new Date('2026-11-23T02:30:00Z'), BA)).toBe('2026-11-22')
    expect(shopDateKey(new Date('2026-11-23T03:30:00Z'), BA)).toBe('2026-11-23')
  })
})

describe('zonedTime', () => {
  it('devuelve la hora de pared del local', () => {
    expect(zonedTime('2026-11-23T12:00:00Z', BA)).toBe('09:00')
    expect(zonedTime('2026-11-23T03:05:00Z', BA)).toBe('00:05')
  })
})

describe('zonedTimeToUtc', () => {
  it('convierte hora de pared del local a UTC', () => {
    expect(zonedTimeToUtc('2026-11-23', '09:00', BA).toISOString()).toBe(
      '2026-11-23T12:00:00.000Z',
    )
  })
})

describe('zonedDayRange', () => {
  it('cubre el día local completo', () => {
    const range = zonedDayRange('2026-11-23', BA)
    expect(range.start.toISOString()).toBe('2026-11-23T03:00:00.000Z')
    expect(range.end.toISOString()).toBe('2026-11-24T03:00:00.000Z')
  })
})

describe('addDaysToDateKey', () => {
  it('cruza fin de mes y año', () => {
    expect(addDaysToDateKey('2026-11-30', 1)).toBe('2026-12-01')
    expect(addDaysToDateKey('2026-12-31', 1)).toBe('2027-01-01')
    expect(addDaysToDateKey('2026-03-01', -1)).toBe('2026-02-28')
    expect(addDaysToDateKey('2026-11-23', 90)).toBe('2027-02-21')
  })
})

describe('timeToMinutes / minutesToTime', () => {
  it('convierte en ambos sentidos', () => {
    expect(timeToMinutes('09:30')).toBe(570)
    expect(minutesToTime(570)).toBe('09:30')
    expect(minutesToTime(0)).toBe('00:00')
  })
})

describe('buildDaySlots', () => {
  const base = {
    openTime: '09:00',
    closeTime: '12:00',
    stepMin: 30,
    durationMin: 45,
    busy: [] as { start: number; end: number }[],
  }

  it('solo genera horarios que terminan antes del cierre', () => {
    const slots = buildDaySlots(base)
    expect(slots.map((slot) => slot.time)).toEqual([
      '09:00',
      '09:30',
      '10:00',
      '10:30',
      '11:00',
    ])
    expect(slots.every((slot) => slot.available)).toBe(true)
  })

  it('marca solapamientos con turnos existentes', () => {
    const busy = [{ start: timeToMinutes('10:00'), end: timeToMinutes('10:30') }]
    const slots = buildDaySlots({ ...base, busy })
    const unavailable = slots.filter((slot) => !slot.available).map((slot) => slot.time)

    // 09:30 termina 10:15 y 10:00 termina 10:45: ambos pisan el turno.
    // 09:00 termina 09:45 y 10:30 arranca justo al liberarse.
    expect(unavailable).toEqual(['09:30', '10:00'])
  })
})

import { describe, expect, it } from 'vitest'
import {
  isRemindable,
  STATUS_ACTIONS,
  STATUS_META,
} from './status'
import type { AppointmentStatus } from '../types/appointment'

const STATUSES: AppointmentStatus[] = [
  'pending',
  'confirmed',
  'in_progress',
  'completed',
  'cancelled',
  'no_show',
]

describe('status metadata', () => {
  it('tiene etiqueta para todos los estados', () => {
    for (const status of STATUSES) {
      expect(STATUS_META[status].label.length).toBeGreaterThan(0)
    }
  })

  it('solo permite recordar turnos pendientes o confirmados', () => {
    expect(STATUSES.filter(isRemindable)).toEqual(['pending', 'confirmed'])
  })
})

describe('status transitions', () => {
  it('solo propone estados válidos', () => {
    for (const status of STATUSES) {
      for (const action of STATUS_ACTIONS[status]) {
        expect(STATUSES).toContain(action.status)
        expect(action.label.length).toBeGreaterThan(0)
      }
    }
  })

  it('no ofrece acciones desde un turno completado', () => {
    expect(STATUS_ACTIONS.completed).toEqual([])
  })

  it('permite reabrir cancelados y ausentes, pero no cancelar dos veces', () => {
    expect(STATUS_ACTIONS.cancelled.map((action) => action.status)).toEqual(['confirmed'])
    expect(STATUS_ACTIONS.no_show.map((action) => action.status)).toEqual(['confirmed'])
    expect(STATUS_ACTIONS.cancelled.some((action) => action.status === 'cancelled')).toBe(false)
  })
})

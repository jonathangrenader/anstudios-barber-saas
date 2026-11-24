import { useCallback, useEffect, useState } from 'react'
import { listAppointmentsForDay } from '../lib/appointments'
import { zonedDayRange } from '../lib/datetime'
import { SYNC_COMPLETE_EVENT } from '../lib/offline/events'
import type { AppointmentView } from '../types/appointment'

export function useAgenda(shopId: string, dateKey: string, timezone: string) {
  const [appointments, setAppointments] = useState<AppointmentView[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { start, end } = zonedDayRange(dateKey, timezone)
      setAppointments(
        await listAppointmentsForDay(shopId, start.toISOString(), end.toISOString()),
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar la agenda.')
    } finally {
      setLoading(false)
    }
  }, [shopId, dateKey, timezone])

  useEffect(() => {
    void reload()
  }, [reload])

  useEffect(() => {
    const handleSync = () => void reload()
    window.addEventListener(SYNC_COMPLETE_EVENT, handleSync)
    return () => window.removeEventListener(SYNC_COMPLETE_EVENT, handleSync)
  }, [reload])

  return { appointments, loading, error, reload }
}

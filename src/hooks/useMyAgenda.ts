import { useCallback, useEffect, useState } from 'react'
import { fetchMyAgenda } from '../lib/staff'
import type { StaffAgendaItem } from '../types/staff'

/** Agenda propia del profesional; online-only porque la calcula la base. */
export function useMyAgenda(dateKey: string) {
  const [appointments, setAppointments] = useState<StaffAgendaItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setAppointments(await fetchMyAgenda(dateKey))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar tu agenda.')
    } finally {
      setLoading(false)
    }
  }, [dateKey])

  useEffect(() => {
    void reload()
  }, [reload])

  return { appointments, loading, error, reload }
}

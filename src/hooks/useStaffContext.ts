import { useCallback, useEffect, useState } from 'react'
import { fetchStaffContext } from '../lib/staff'
import type { StaffContext } from '../types/staff'

/** Resuelve si la cuenta logueada es un profesional vinculado a un local. */
export function useStaffContext() {
  const [context, setContext] = useState<StaffContext | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setContext(await fetchStaffContext())
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar tu acceso.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void reload()
  }, [reload])

  return { context, setContext, loading, error, reload }
}

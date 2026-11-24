import { useCallback, useEffect, useState } from 'react'
import { listCashMovements } from '../lib/cash'
import { zonedDayRange } from '../lib/datetime'
import { SYNC_COMPLETE_EVENT } from '../lib/offline/events'
import type { CashMovementView } from '../types/cash'

export function useCash(shopId: string, dateKey: string, timezone: string) {
  const [movements, setMovements] = useState<CashMovementView[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { start, end } = zonedDayRange(dateKey, timezone)
      setMovements(
        await listCashMovements(shopId, start.toISOString(), end.toISOString()),
      )
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar la caja.')
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

  return { movements, loading, error, reload }
}

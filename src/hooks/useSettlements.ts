import { useCallback, useEffect, useState } from 'react'
import { listStaffSettlements } from '../lib/settlements'
import type { StaffSettlementSummary } from '../types/settlement'

export function useSettlements(shopId: string) {
  const [settlements, setSettlements] = useState<StaffSettlementSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setSettlements(await listStaffSettlements(shopId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar las liquidaciones.')
    } finally {
      setLoading(false)
    }
  }, [shopId])

  useEffect(() => {
    void reload()
  }, [reload])

  return { settlements, loading, error, reload }
}

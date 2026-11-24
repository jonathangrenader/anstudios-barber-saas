import { useCallback, useEffect, useState } from 'react'
import { fetchOwnShop } from '../lib/shops'
import type { Shop } from '../types/shop'

export function useShop(userId: string) {
  const [shop, setShop] = useState<Shop | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setShop(await fetchOwnShop(userId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar tu local.')
    } finally {
      setLoading(false)
    }
  }, [userId])

  useEffect(() => {
    void load()
  }, [load])

  return { shop, loading, error, reload: load, adopt: setShop }
}

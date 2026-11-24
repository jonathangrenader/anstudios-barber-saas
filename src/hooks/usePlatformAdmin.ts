import { useCallback, useEffect, useState } from 'react'
import { fetchPlatformMe } from '../lib/platform'
import type { PlatformMe } from '../types/platform'

const NONE: PlatformMe = { is_admin: false, has_shop: false }

/** Si la migración de plataforma no está aplicada, la app sigue funcionando como local. */
export function usePlatformAdmin(userId: string | null) {
  const [me, setMe] = useState<PlatformMe>(NONE)
  const [loading, setLoading] = useState(Boolean(userId))
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!userId) {
      setMe(NONE)
      setError(null)
      setLoading(false)
      return
    }

    setLoading(true)
    setError(null)
    try {
      setMe(await fetchPlatformMe())
    } catch (err) {
      setMe(NONE)
      setError(err instanceof Error ? err.message : 'No pudimos verificar tu acceso.')
    } finally {
      setLoading(false)
    }
  }, [userId])

  useEffect(() => {
    void load()
  }, [load])

  return { ...me, loading, error, reload: load }
}

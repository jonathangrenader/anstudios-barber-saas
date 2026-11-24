import { useCallback, useEffect, useState } from 'react'
import { createClient, listClients, updateClient } from '../lib/clients'
import { SYNC_COMPLETE_EVENT } from '../lib/offline/events'
import type { Client, ClientInput } from '../types/client'

export function useClients(shopId: string) {
  const [clients, setClients] = useState<Client[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const rows = await listClients(shopId)
      setClients(rows)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar los clientes.')
    } finally {
      setLoading(false)
    }
  }, [shopId])

  useEffect(() => {
    void reload()
  }, [reload])

  useEffect(() => {
    const handleSync = () => void reload()
    window.addEventListener(SYNC_COMPLETE_EVENT, handleSync)
    return () => window.removeEventListener(SYNC_COMPLETE_EVENT, handleSync)
  }, [reload])

  const save = useCallback(
    async (input: ClientInput, id?: string) => {
      const result = id
        ? await updateClient(id, shopId, input)
        : await createClient(shopId, input).then((client) => ({
            queued: client.sync_status === 'pending',
            id: client.id,
          }))
      await reload()
      return result
    },
    [shopId, reload],
  )

  return { clients, loading, error, reload, save }
}

import { useCallback, useEffect, useState } from 'react'
import {
  createCatalogItem,
  deleteCatalogItem,
  listCatalog,
  updateCatalogItem,
} from '../lib/catalog'
import type { CatalogItem, CatalogItemInput } from '../types/catalog'

export function useCatalog(shopId: string) {
  const [items, setItems] = useState<CatalogItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setItems(await listCatalog(shopId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar el catálogo.')
    } finally {
      setLoading(false)
    }
  }, [shopId])

  useEffect(() => {
    void reload()
  }, [reload])

  const save = useCallback(
    async (input: CatalogItemInput, id?: string) => {
      if (id) await updateCatalogItem(id, input)
      else await createCatalogItem(shopId, input)
      await reload()
    },
    [shopId, reload],
  )

  const remove = useCallback(
    async (id: string) => {
      await deleteCatalogItem(id)
      await reload()
    },
    [reload],
  )

  const toggleActive = useCallback(
    async (item: CatalogItem) => {
      await updateCatalogItem(item.id, { is_active: !item.is_active })
      await reload()
    },
    [reload],
  )

  return { items, loading, error, reload, save, remove, toggleActive }
}

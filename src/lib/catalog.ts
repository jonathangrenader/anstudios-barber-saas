import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'
import { cachedQuery } from './offline/cache'
import { cacheKeys } from './offline/keys'
import type { CatalogItem, CatalogItemInput } from '../types/catalog'

type CatalogRow = Omit<CatalogItem, 'price' | 'default_supply_cost'> & {
  price: number | string
  default_supply_cost: number | string
}

function mapItem(row: CatalogRow): CatalogItem {
  return {
    ...row,
    price: Number(row.price),
    default_supply_cost: Number(row.default_supply_cost),
  }
}

export async function listCatalog(shopId: string): Promise<CatalogItem[]> {
  return cachedQuery(
    cacheKeys.catalog(shopId),
    async () => {
      const { data, error } = await supabase
        .from('catalog_items')
        .select('*')
        .eq('shop_id', shopId)
        .order('type')
        .order('name')

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar el catálogo.'))
      return ((data ?? []) as CatalogRow[]).map(mapItem)
    },
    'Sin conexión y sin catálogo guardado. Conectate una vez para poder consultarlo offline.',
  )
}

export async function createCatalogItem(
  shopId: string,
  input: CatalogItemInput,
): Promise<CatalogItem> {
  const { data, error } = await supabase
    .from('catalog_items')
    .insert({ ...input, shop_id: shopId })
    .select('*')
    .single()

  if (error) throw new Error(dbErrorMessage(error, 'No pudimos crear el ítem.'))
  return mapItem(data as CatalogRow)
}

export async function updateCatalogItem(
  id: string,
  patch: Partial<CatalogItemInput>,
): Promise<void> {
  const { error } = await supabase.from('catalog_items').update(patch).eq('id', id)
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos actualizar el ítem.'))
}

export async function deleteCatalogItem(id: string): Promise<void> {
  const { error } = await supabase.from('catalog_items').delete().eq('id', id)
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos eliminar el ítem.'))
}

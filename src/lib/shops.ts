import { supabase } from './supabase'
import { cachedQuery } from './offline/cache'
import { cacheSet } from './offline/db'
import { cacheKeys } from './offline/keys'
import type { Shop, ShopInput } from '../types/shop'

/** Minúsculas, sin acentos, solo [a-z0-9-], sin guiones repetidos ni en los extremos. */
export function normalizeSlug(raw: string): string {
  return raw
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '')
}

export const SLUG_PATTERN = /^[a-z0-9-]{3,60}$/

export async function fetchOwnShop(userId: string): Promise<Shop | null> {
  return cachedQuery(
    cacheKeys.shop(userId),
    async () => {
      const { data, error } = await supabase
        .from('shops')
        .select('*')
        .eq('owner_id', userId)
        .order('created_at', { ascending: true })
        .limit(1)
        .maybeSingle()

      if (error) throw new Error(error.message)
      return (data as Shop | null) ?? null
    },
    'Sin conexión y sin datos guardados del local. Conectate una vez para poder abrirlo offline.',
  )
}

export async function createShop(userId: string, input: ShopInput): Promise<Shop> {
  const { data, error } = await supabase
    .from('shops')
    .insert({ ...input, owner_id: userId })
    .select('*')
    .single()

  if (error) {
    // 23505 = unique_violation sobre shops.slug
    if (error.code === '23505') {
      throw new Error('Ese slug ya está en uso. Probá con otro.')
    }
    throw new Error(error.message)
  }

  const shop = data as Shop
  await cacheSet(cacheKeys.shop(userId), shop)
  return shop
}

export async function updateShop(
  shopId: string,
  ownerId: string,
  patch: Partial<ShopInput>,
): Promise<Shop> {
  const { data, error } = await supabase
    .from('shops')
    .update(patch)
    .eq('id', shopId)
    .select('*')
    .single()

  if (error) {
    if (error.code === '23505') {
      throw new Error('Ese slug ya está en uso. Probá con otro.')
    }
    throw new Error(error.message)
  }

  const shop = data as Shop
  await cacheSet(cacheKeys.shop(ownerId), shop)
  return shop
}

/** Link de Maps: usa el cargado o busca la dirección del local. */
export function mapsHref(shop: Pick<Shop, 'maps_url' | 'address'>): string | null {
  if (shop.maps_url) return shop.maps_url
  if (shop.address) {
    return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(shop.address)}`
  }
  return null
}

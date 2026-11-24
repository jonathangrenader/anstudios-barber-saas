import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'
import type { PlatformMe, PlatformShop } from '../types/platform'
import type { ShopAccess } from '../types/shop'

export async function fetchPlatformMe(): Promise<PlatformMe> {
  const { data, error } = await supabase.rpc('fn_platform_me')
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos verificar tu acceso.'))

  const payload = (data ?? {}) as Partial<PlatformMe>
  return {
    is_admin: Boolean(payload.is_admin),
    has_shop: Boolean(payload.has_shop),
  }
}

export async function listPlatformShops(): Promise<PlatformShop[]> {
  const { data, error } = await supabase.rpc('fn_platform_shops')
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar los locales.'))

  return Array.isArray(data) ? (data as PlatformShop[]) : []
}

export async function setShopSuspension(
  shopId: string,
  suspended: boolean,
  note: string | null = null,
): Promise<ShopAccess> {
  const { data, error } = await supabase.rpc('fn_platform_set_suspension', {
    p_shop_id: shopId,
    p_suspended: suspended,
    p_note: note,
  })
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos cambiar el estado del local.'))
  return data as ShopAccess
}

/** `days = 0` quita la prueba; 90 es el valor por defecto del panel. */
export async function setShopTrial(shopId: string, days: number): Promise<ShopAccess> {
  const { data, error } = await supabase.rpc('fn_platform_set_trial', {
    p_shop_id: shopId,
    p_days: days,
  })
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos actualizar la prueba.'))
  return data as ShopAccess
}

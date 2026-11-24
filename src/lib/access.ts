import type { Shop, ShopAccess, ShopAccessState } from '../types/shop'

/** Mismo criterio que `fn_shop_access`: la suspensión gana sobre la prueba. */
export function shopAccessState(
  shop: Pick<Shop, 'is_suspended' | 'trial_ends_at'>,
  now = Date.now(),
): ShopAccessState {
  if (shop.is_suspended) return 'suspended'
  if (shop.trial_ends_at) {
    const endsAt = Date.parse(shop.trial_ends_at)
    if (Number.isFinite(endsAt) && endsAt <= now) return 'trial_expired'
    return 'trial'
  }
  return 'active'
}

export function isShopBlocked(shop: Pick<Shop, 'is_suspended' | 'trial_ends_at'>): boolean {
  const state = shopAccessState(shop)
  return state === 'suspended' || state === 'trial_expired'
}

export function trialDaysLeft(endsAt: string, now = Date.now()): number {
  const remaining = Date.parse(endsAt) - now
  if (!Number.isFinite(remaining) || remaining <= 0) return 0
  return Math.ceil(remaining / 86_400_000)
}

export function accessFromShop(shop: Shop): ShopAccess {
  return {
    state: shopAccessState(shop),
    trial_ends_at: shop.trial_ends_at,
    days_left: shop.trial_ends_at ? trialDaysLeft(shop.trial_ends_at) : 0,
    suspended_at: shop.suspended_at,
    suspension_note: shop.suspension_note,
  }
}

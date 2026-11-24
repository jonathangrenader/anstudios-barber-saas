export const cacheKeys = {
  shop: (userId: string) => `shop:${userId}`,
  staff: (shopId: string) => `staff:${shopId}`,
  catalog: (shopId: string) => `catalog:${shopId}`,
  clients: (shopId: string) => `clients:${shopId}`,
  agenda: (shopId: string, startIso: string, endIso: string) =>
    `agenda:${shopId}:${startIso}:${endIso}`,
  cash: (shopId: string, startIso: string, endIso: string) =>
    `cash:${shopId}:${startIso}:${endIso}`,
}

export type CatalogItemType = 'service' | 'product'

export interface CatalogItem {
  id: string
  shop_id: string
  type: CatalogItemType
  name: string
  duration_min: number
  price: number
  default_supply_cost: number
  is_public: boolean
  is_active: boolean
  created_at: string
}

export type CatalogItemInput = Omit<CatalogItem, 'id' | 'shop_id' | 'created_at'>

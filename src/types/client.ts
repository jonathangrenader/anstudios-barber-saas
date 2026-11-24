export interface Client {
  id: string
  shop_id: string
  full_name: string
  phone: string
  technical_notes: string | null
  last_visit_at: string | null
  total_visits: number
  created_at: string
  sync_status?: 'pending' | 'failed'
}

export type ClientInput = Pick<Client, 'full_name' | 'phone' | 'technical_notes'>


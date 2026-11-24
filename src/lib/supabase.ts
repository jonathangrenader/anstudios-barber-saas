import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Faltan variables de entorno: definí VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY en .env.local (ver .env.example).',
  )
}

/**
 * Cliente único de Supabase para toda la app.
 * La RLS del proyecto se encarga del aislamiento por `shop_id`; acá solo se usa la anon key.
 */
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
})

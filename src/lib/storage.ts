import { supabase } from './supabase'

const MAX_BYTES = 5 * 1024 * 1024
const ALLOWED = ['image/jpeg', 'image/png', 'image/webp']

function extensionFor(type: string): string {
  if (type === 'image/png') return 'png'
  if (type === 'image/webp') return 'webp'
  return 'jpg'
}

/**
 * Sube una imagen al bucket público `media`.
 * `prefix` debe ser `shops/<shop_id>` o `staff/<staff_id>` (lo valida Storage RLS).
 */
export async function uploadImage(prefix: string, file: File): Promise<string> {
  if (!ALLOWED.includes(file.type)) {
    throw new Error('Formato no admitido. Usá JPG, PNG o WebP.')
  }
  if (file.size > MAX_BYTES) {
    throw new Error('La imagen supera los 5 MB.')
  }

  const path = `${prefix}/${crypto.randomUUID()}.${extensionFor(file.type)}`
  const { error } = await supabase.storage.from('media').upload(path, file, {
    cacheControl: '3600',
    contentType: file.type,
    upsert: false,
  })

  if (error) {
    throw new Error(
      'No pudimos subir la imagen. Verificá que las políticas de Storage estén aplicadas.',
    )
  }

  return supabase.storage.from('media').getPublicUrl(path).data.publicUrl
}

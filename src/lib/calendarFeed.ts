import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'

/**
 * URL pública del feed ICS de un profesional. Es una URL de capacidad:
 * quien la tenga puede leer los turnos, así que se comparte solo con el
 * profesional. Se puede revocar regenerando el token.
 */
export function calendarFeedUrl(token: string): string {
  const base = import.meta.env.VITE_SUPABASE_URL as string | undefined
  if (!base) throw new Error('Falta VITE_SUPABASE_URL para armar el link del calendario.')
  return `${base.replace(/\/$/, '')}/functions/v1/calendar-feed?token=${token}`
}

export async function getCalendarToken(staffId?: string): Promise<string> {
  const { data, error } = await supabase.rpc('fn_calendar_token', {
    p_staff_id: staffId ?? null,
  })
  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos obtener el link del calendario.'))
  }
  if (typeof data !== 'string') throw new Error('El servidor no devolvió el link del calendario.')
  return data
}

export async function rotateCalendarToken(staffId?: string): Promise<string> {
  const { data, error } = await supabase.rpc('fn_rotate_calendar_token', {
    p_staff_id: staffId ?? null,
  })
  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos regenerar el link del calendario.'))
  }
  if (typeof data !== 'string') throw new Error('El servidor no devolvió el link del calendario.')
  return data
}

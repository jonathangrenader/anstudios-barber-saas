type DbError = { code?: string; message: string }

export function dbErrorMessage(error: DbError, fallback: string): string {
  if (error.code === '42501') return 'No tenés permiso para esta acción.'
  if (error.code === '23514') return 'Algunos datos no respetan las reglas del local.'
  if (error.code === '23505') return 'Ese registro ya existe.'
  if (error.code === '23503') return 'No se puede completar: hay datos relacionados.'
  return error.message || fallback
}

const NETWORK_PATTERNS = [
  /failed to fetch/i,
  /fetch failed/i,
  /network ?error/i,
  /load failed/i,
  /err_internet_disconnected/i,
  /err_network/i,
  /network connection/i,
  /request timed out/i,
  /timeout/i,
]

export function isBrowserOffline(): boolean {
  return typeof navigator !== 'undefined' && navigator.onLine === false
}

/** Solo errores de transporte: los errores SQL/RLS nunca deben caer al caché. */
export function isNetworkError(error: unknown): boolean {
  if (isBrowserOffline()) return true
  if (!error || typeof error !== 'object') return false
  const message =
    'message' in error && typeof error.message === 'string' ? error.message : ''
  const name = 'name' in error && typeof error.name === 'string' ? error.name : ''
  if (/AuthRetryableFetchError|FetchError|NetworkError/i.test(name)) return true
  return NETWORK_PATTERNS.some((pattern) => pattern.test(message))
}

export function newLocalId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }

  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (char) => {
    const random = Math.floor(Math.random() * 16)
    const value = char === 'x' ? random : (random & 0x3) | 0x8
    return value.toString(16)
  })
}

export function offlineReadMessage(what: string): string {
  return `Sin conexión y sin datos guardados de ${what}. Conectate una vez para poder consultarlo offline.`
}

import { cacheGet, cacheSet } from './db'
import { emitNetworkDown, emitNetworkUp } from './events'
import { isBrowserOffline, isNetworkError } from './network'

/**
 * Devuelve la respuesta de red y la guarda, o la última copia local si el
 * problema es de conexión. Los errores de negocio/RLS no se ocultan con caché.
 */
export async function cachedQuery<T>(
  key: string,
  fetcher: () => Promise<T>,
  offlineMessage: string,
): Promise<T> {
  const cached = await cacheGet<T>(key)

  if (isBrowserOffline()) {
    emitNetworkDown()
    if (cached !== undefined) return cached
    throw new Error(offlineMessage)
  }

  try {
    const value = await fetcher()
    await cacheSet(key, value)
    emitNetworkUp()
    return value
  } catch (error) {
    if (isNetworkError(error)) {
      emitNetworkDown()
      if (cached !== undefined) return cached
      throw new Error(offlineMessage)
    }
    throw error
  }
}

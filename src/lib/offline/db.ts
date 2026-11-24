import type { OutboxItem } from './types'

const DB_NAME = 'anstudios-offline'
const DB_VERSION = 1
const CACHE_STORE = 'cache'
const OUTBOX_STORE = 'outbox'
const SHOP_INDEX = 'by_shop'

let dbPromise: Promise<IDBDatabase> | null = null

function openDb(): Promise<IDBDatabase> {
  if (typeof indexedDB === 'undefined') {
    return Promise.reject(new Error('Este navegador no soporta almacenamiento local.'))
  }

  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION)

      request.onupgradeneeded = () => {
        const db = request.result
        if (!db.objectStoreNames.contains(CACHE_STORE)) {
          db.createObjectStore(CACHE_STORE)
        }
        if (!db.objectStoreNames.contains(OUTBOX_STORE)) {
          const outbox = db.createObjectStore(OUTBOX_STORE, { keyPath: 'id' })
          outbox.createIndex(SHOP_INDEX, 'shopId', { unique: false })
        }
      }

      request.onsuccess = () => {
        const db = request.result
        db.onversionchange = () => db.close()
        resolve(db)
      }
      request.onerror = () =>
        reject(request.error ?? new Error('No pudimos abrir el almacenamiento local.'))
    })

    void dbPromise.catch(() => {
      dbPromise = null
    })
  }

  return dbPromise
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error('Error de IndexedDB.'))
  })
}

function transactionDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve()
    tx.onerror = () => reject(tx.error ?? new Error('No pudimos guardar los datos.'))
    tx.onabort = () => reject(tx.error ?? new Error('Se canceló el guardado local.'))
  })
}

export async function cacheGet<T>(key: string): Promise<T | undefined> {
  try {
    const db = await openDb()
    const tx = db.transaction(CACHE_STORE, 'readonly')
    const request = tx.objectStore(CACHE_STORE).get(key)
    return (await requestResult(request)) as T | undefined
  } catch {
    return undefined
  }
}

export async function cacheSet<T>(key: string, value: T): Promise<void> {
  try {
    const db = await openDb()
    const tx = db.transaction(CACHE_STORE, 'readwrite')
    tx.objectStore(CACHE_STORE).put(value, key)
    await transactionDone(tx)
  } catch {
    // El caché es best-effort: si no está disponible, la app sigue online.
  }
}

export async function addOutbox(item: OutboxItem): Promise<void> {
  const db = await openDb()
  const tx = db.transaction(OUTBOX_STORE, 'readwrite')
  tx.objectStore(OUTBOX_STORE).put(item)
  await transactionDone(tx)
}

export async function updateOutbox(item: OutboxItem): Promise<void> {
  const db = await openDb()
  const tx = db.transaction(OUTBOX_STORE, 'readwrite')
  tx.objectStore(OUTBOX_STORE).put(item)
  await transactionDone(tx)
}

export async function deleteOutbox(id: string): Promise<void> {
  const db = await openDb()
  const tx = db.transaction(OUTBOX_STORE, 'readwrite')
  tx.objectStore(OUTBOX_STORE).delete(id)
  await transactionDone(tx)
}

export async function getOutboxItem(id: string): Promise<OutboxItem | undefined> {
  try {
    const db = await openDb()
    const tx = db.transaction(OUTBOX_STORE, 'readonly')
    return (await requestResult(tx.objectStore(OUTBOX_STORE).get(id))) as
      | OutboxItem
      | undefined
  } catch {
    return undefined
  }
}

export async function getOutbox(shopId: string): Promise<OutboxItem[]> {
  try {
    const db = await openDb()
    const tx = db.transaction(OUTBOX_STORE, 'readonly')
    const index = tx.objectStore(OUTBOX_STORE).index(SHOP_INDEX)
    const rows = (await requestResult(index.getAll(shopId))) as OutboxItem[]
    return rows.sort((a, b) => a.createdAt.localeCompare(b.createdAt))
  } catch {
    return []
  }
}

export async function getOutboxSnapshot(
  shopId: string,
): Promise<{ pending: number; failed: number; lastError: string | null }> {
  const rows = await getOutbox(shopId)
  const failedRows = rows.filter((row) => row.status === 'failed')
  return {
    pending: rows.filter((row) => row.status === 'pending').length,
    failed: failedRows.length,
    lastError: failedRows[0]?.lastError ?? null,
  }
}

export async function retryFailedOutbox(shopId: string): Promise<void> {
  const rows = await getOutbox(shopId)
  const failed = rows.filter((row) => row.status === 'failed')
  if (failed.length === 0) return

  const db = await openDb()
  const tx = db.transaction(OUTBOX_STORE, 'readwrite')
  const store = tx.objectStore(OUTBOX_STORE)
  for (const row of failed) {
    store.put({ ...row, status: 'pending', lastError: null, attempts: 0 })
  }
  await transactionDone(tx)
}

/**
 * Si un cliente creado offline ya existía por teléfono, reemplaza su id local
 * en los turnos y ediciones que todavía están en la cola.
 */
export async function remapClientInOutbox(
  shopId: string,
  localId: string,
  serverId: string,
): Promise<void> {
  const rows = await getOutbox(shopId)
  const affected = rows.filter(
    (row) =>
      (row.type === 'appointment.create' && row.payload.client_id === localId) ||
      (row.type === 'client.update' && row.payload.id === localId),
  )
  if (affected.length === 0) return

  const db = await openDb()
  const tx = db.transaction(OUTBOX_STORE, 'readwrite')
  const store = tx.objectStore(OUTBOX_STORE)
  for (const row of affected) {
    if (row.type === 'appointment.create') {
      store.put({ ...row, payload: { ...row.payload, client_id: serverId } })
    } else if (row.type === 'client.update') {
      store.put({ ...row, payload: { ...row.payload, id: serverId } })
    }
  }
  await transactionDone(tx)
}

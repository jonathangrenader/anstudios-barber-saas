export const OUTBOX_CHANGED_EVENT = 'anstudios:outbox-changed'
export const SYNC_COMPLETE_EVENT = 'anstudios:sync-complete'
export const NETWORK_DOWN_EVENT = 'anstudios:network-down'
export const NETWORK_UP_EVENT = 'anstudios:network-up'

export function emitOutboxChanged(): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(OUTBOX_CHANGED_EVENT))
  }
}

export function emitSyncComplete(): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(SYNC_COMPLETE_EVENT))
  }
}

export function emitNetworkDown(): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(NETWORK_DOWN_EVENT))
  }
}

export function emitNetworkUp(): void {
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(NETWORK_UP_EVENT))
  }
}

import { useCallback, useEffect, useState } from 'react'
import {
  NETWORK_DOWN_EVENT,
  NETWORK_UP_EVENT,
  OUTBOX_CHANGED_EVENT,
} from '../lib/offline/events'
import { isBrowserOffline } from '../lib/offline/network'
import {
  getOfflineState,
  refreshOfflineState,
  retryFailedAndSync,
  setNetworkReachable,
  subscribeOfflineState,
  syncOutbox,
} from '../lib/offline/sync'
import type { OfflineState, SyncResult } from '../lib/offline/types'

export function useOfflineSync(shopId: string): OfflineState & {
  syncNow: (retryFailed?: boolean) => Promise<SyncResult>
} {
  const [state, setState] = useState<OfflineState>(() => getOfflineState())

  useEffect(() => subscribeOfflineState(setState), [])

  useEffect(() => {
    void refreshOfflineState(shopId)
    if (!isBrowserOffline()) void syncOutbox(shopId)
  }, [shopId])

  useEffect(() => {
    function handleOnline() {
      void refreshOfflineState(shopId)
      void syncOutbox(shopId)
    }
    function handleOffline() {
      void refreshOfflineState(shopId)
    }
    function handleVisibility() {
      if (document.visibilityState === 'visible' && !isBrowserOffline()) {
        void syncOutbox(shopId)
      }
    }
    function handleOutboxChanged() {
      void refreshOfflineState(shopId)
    }
    function handleNetworkDown() {
      setNetworkReachable(false)
    }
    function handleNetworkUp() {
      setNetworkReachable(true)
      if (getOfflineState().pending > 0) void syncOutbox(shopId)
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    window.addEventListener(OUTBOX_CHANGED_EVENT, handleOutboxChanged)
    window.addEventListener(NETWORK_DOWN_EVENT, handleNetworkDown)
    window.addEventListener(NETWORK_UP_EVENT, handleNetworkUp)
    document.addEventListener('visibilitychange', handleVisibility)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
      window.removeEventListener(OUTBOX_CHANGED_EVENT, handleOutboxChanged)
      window.removeEventListener(NETWORK_DOWN_EVENT, handleNetworkDown)
      window.removeEventListener(NETWORK_UP_EVENT, handleNetworkUp)
      document.removeEventListener('visibilitychange', handleVisibility)
    }
  }, [shopId])

  const syncNow = useCallback(
    (retryFailed = false) =>
      retryFailed ? retryFailedAndSync(shopId) : syncOutbox(shopId),
    [shopId],
  )

  return { ...state, syncNow }
}

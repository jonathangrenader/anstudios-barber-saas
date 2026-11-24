import { AlertTriangle, CloudOff, Loader2, RefreshCw } from 'lucide-react'
import type { OfflineState } from '../lib/offline/types'

export function OfflineBanner({
  state,
  onRetry,
}: {
  state: OfflineState
  onRetry: () => void
}) {
  if (state.online && state.pending === 0 && state.failed === 0) return null

  if (!state.online) {
    return (
      <div
        role="status"
        className="mb-4 rounded-xl border border-pending/40 bg-pending-soft px-3 py-2.5 text-xs text-pending"
      >
        <p className="flex items-center gap-2 font-semibold">
          <CloudOff size={15} aria-hidden="true" />
          Sin conexión
        </p>
        <p className="mt-1 leading-relaxed">
          Podés seguir usando la agenda y la caja guardadas. Los cambios se
          sincronizarán al reconectar.
          {state.pending > 0
            ? ` ${state.pending} ${state.pending === 1 ? 'cambio pendiente' : 'cambios pendientes'}.`
            : ''}
        </p>
        <button
          type="button"
          onClick={onRetry}
          disabled={state.syncing}
          className="mt-2 inline-flex min-h-[44px] items-center gap-1.5 rounded-lg border border-pending/30 bg-surface px-3 font-semibold text-pending disabled:opacity-60"
        >
          {state.syncing ? (
            <Loader2 size={14} className="animate-spin" aria-hidden="true" />
          ) : (
            <RefreshCw size={14} aria-hidden="true" />
          )}
          Probar de nuevo
        </button>
      </div>
    )
  }

  if (state.failed > 0) {
    return (
      <div
        role="alert"
        className="mb-4 rounded-xl border border-expense/30 bg-expense-soft px-3 py-2.5 text-xs text-expense"
      >
        <p className="flex items-center gap-2 font-semibold">
          <AlertTriangle size={15} aria-hidden="true" />
          {state.failed} {state.failed === 1 ? 'cambio no se pudo sincronizar' : 'cambios no se pudieron sincronizar'}
        </p>
        {state.lastError && <p className="mt-1 leading-relaxed">{state.lastError}</p>}
        <button
          type="button"
          onClick={onRetry}
          disabled={state.syncing}
          className="mt-2 inline-flex min-h-[44px] items-center gap-1.5 rounded-lg border border-expense/30 bg-surface px-3 font-semibold text-expense disabled:opacity-60"
        >
          {state.syncing ? (
            <Loader2 size={14} className="animate-spin" aria-hidden="true" />
          ) : (
            <RefreshCw size={14} aria-hidden="true" />
          )}
          Reintentar
        </button>
      </div>
    )
  }

  return (
    <div
      role="status"
      className="mb-4 flex items-center justify-between gap-3 rounded-xl border border-pending/30 bg-pending-soft px-3 py-2 text-xs text-pending"
    >
      <p className="flex items-center gap-2 font-semibold">
        {state.syncing ? (
          <Loader2 size={14} className="animate-spin" aria-hidden="true" />
        ) : (
          <RefreshCw size={14} aria-hidden="true" />
        )}
        {state.syncing
          ? 'Sincronizando cambios…'
          : `${state.pending} ${state.pending === 1 ? 'cambio pendiente' : 'cambios pendientes'}`}
      </p>
      {!state.syncing && (
        <button
          type="button"
          onClick={onRetry}
          className="inline-flex min-h-[44px] shrink-0 items-center rounded-lg px-2 font-semibold underline underline-offset-4"
        >
          Reintentar
        </button>
      )}
    </div>
  )
}

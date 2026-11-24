import { useCallback, useEffect, useState } from 'react'
import {
  CalendarPlus,
  CheckCircle2,
  Loader2,
  LogOut,
  RefreshCw,
  ShieldCheck,
  Store,
  TriangleAlert,
  Undo2,
} from 'lucide-react'
import { shopAccessState, trialDaysLeft } from '../lib/access'
import { listPlatformShops, setShopSuspension, setShopTrial } from '../lib/platform'
import type { PlatformShop } from '../types/platform'
import type { ShopAccessState } from '../types/shop'

function shortDate(iso: string | null): string {
  if (!iso) return '—'
  return new Intl.DateTimeFormat('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(new Date(iso))
}

const STATUS_LABEL: Record<ShopAccessState, string> = {
  active: 'Activo',
  trial: 'En prueba',
  trial_expired: 'Prueba vencida',
  suspended: 'Suspendido',
}

function statusClasses(state: ShopAccessState): string {
  if (state === 'active') return 'bg-income-soft text-income'
  if (state === 'trial') return 'bg-pending-soft text-pending'
  return 'bg-expense-soft text-expense'
}

export function PlatformAdminScreen({
  email,
  hasShop,
  onOpenShop,
  onSignOut,
}: {
  email: string
  hasShop: boolean
  onOpenShop: () => void
  onSignOut: () => void
}) {
  const [shops, setShops] = useState<PlatformShop[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [pendingId, setPendingId] = useState<string | null>(null)

  const load = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setShops(await listPlatformShops())
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar los locales.')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  async function run(shopId: string, action: () => Promise<unknown>) {
    setPendingId(shopId)
    setError(null)
    try {
      await action()
      await load()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos aplicar el cambio.')
    } finally {
      setPendingId(null)
    }
  }

  function toggleSuspension(shop: PlatformShop) {
    const suspending = !shop.is_suspended
    const confirmed = window.confirm(
      suspending
        ? `¿Suspender "${shop.name}"? No va a poder usar la app ni recibir reservas online.`
        : `¿Habilitar "${shop.name}" de nuevo?`,
    )
    if (!confirmed) return
    void run(shop.id, () => setShopSuspension(shop.id, suspending))
  }

  function grantTrial(shop: PlatformShop) {
    void run(shop.id, () => setShopTrial(shop.id, 90))
  }

  function clearTrial(shop: PlatformShop) {
    if (!window.confirm(`¿Quitar la prueba gratuita de "${shop.name}"?`)) return
    void run(shop.id, () => setShopTrial(shop.id, 0))
  }

  const active = shops.filter((shop) => shopAccessState(shop) === 'active').length
  const trialing = shops.filter((shop) => shopAccessState(shop) === 'trial').length
  const blocked = shops.length - active - trialing

  return (
    <main className="mx-auto w-full max-w-2xl px-5 pb-12 pt-8">
      <header className="mb-6 flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2.5">
          <span className="flex size-10 shrink-0 items-center justify-center rounded-lg border border-strong bg-brand-primary text-white">
            <ShieldCheck size={20} aria-hidden="true" />
          </span>
          <div className="min-w-0">
            <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">
              ANSTUDIOS
            </p>
            <h1 className="truncate text-xl font-bold leading-tight">Panel de plataforma</h1>
            <p className="truncate text-xs text-muted">{email}</p>
          </div>
        </div>

        <div className="flex shrink-0 items-center gap-2">
          {hasShop && (
            <button
              type="button"
              onClick={onOpenShop}
              className="inline-flex min-h-[44px] items-center gap-2 rounded-lg border border-base bg-surface px-3 text-sm font-medium text-muted hover:bg-surface-alt"
            >
              <Store size={16} aria-hidden="true" />
              <span className="hidden sm:inline">Mi local</span>
            </button>
          )}
          <button
            type="button"
            onClick={onSignOut}
            aria-label="Cerrar sesión"
            className="inline-flex min-h-[44px] items-center gap-2 rounded-lg border border-base bg-surface px-3 text-sm font-medium text-muted hover:bg-surface-alt"
          >
            <LogOut size={16} aria-hidden="true" />
            <span className="hidden sm:inline">Salir</span>
          </button>
        </div>
      </header>

      <div className="mb-5 grid grid-cols-3 gap-2 text-center">
        <div className="rounded-lg border border-base bg-surface px-2 py-3">
          <p className="numeric text-lg font-bold">{active}</p>
          <p className="text-[11px] font-medium uppercase tracking-[0.1em] text-muted">Activos</p>
        </div>
        <div className="rounded-lg border border-base bg-surface px-2 py-3">
          <p className="numeric text-lg font-bold">{trialing}</p>
          <p className="text-[11px] font-medium uppercase tracking-[0.1em] text-muted">En prueba</p>
        </div>
        <div className="rounded-lg border border-base bg-surface px-2 py-3">
          <p className="numeric text-lg font-bold">{blocked}</p>
          <p className="text-[11px] font-medium uppercase tracking-[0.1em] text-muted">
            Bloqueados
          </p>
        </div>
      </div>

      <div className="mb-4 flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold">Locales ({shops.length})</h2>
        <button
          type="button"
          onClick={() => void load()}
          disabled={loading}
          className="inline-flex min-h-[44px] items-center gap-1.5 text-sm font-medium text-muted hover:text-ink disabled:opacity-60"
        >
          <RefreshCw size={15} className={loading ? 'animate-spin' : undefined} aria-hidden="true" />
          Actualizar
        </button>
      </div>

      {error && (
        <p
          role="alert"
          className="mb-4 rounded-lg border border-expense/30 bg-expense-soft px-3 py-2 text-xs font-medium text-expense"
        >
          {error}
        </p>
      )}

      {loading && shops.length === 0 ? (
        <p className="flex items-center gap-2 py-6 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando locales…
        </p>
      ) : shops.length === 0 ? (
        <p className="rounded-xl border border-base bg-surface p-4 text-sm text-muted">
          Todavía no hay locales creados.
        </p>
      ) : (
        <ul className="space-y-3">
          {shops.map((shop) => {
            const state = shopAccessState(shop)
            const busy = pendingId === shop.id

            return (
              <li key={shop.id}>
                <article className="rounded-xl border border-base bg-surface p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <h3 className="truncate text-base font-semibold">{shop.name}</h3>
                      <p className="truncate text-xs text-muted">
                        /r/{shop.slug} · {shop.owner_email ?? 'sin email'}
                        {shop.is_mine ? ' · tu local' : ''}
                      </p>
                    </div>
                    <span
                      className={`shrink-0 rounded-md px-2 py-1 text-[11px] font-semibold uppercase tracking-[0.1em] ${statusClasses(state)}`}
                    >
                      {STATUS_LABEL[state]}
                    </span>
                  </div>

                  <dl className="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5 text-xs">
                    <div>
                      <dt className="text-muted">Alta</dt>
                      <dd className="numeric">{shortDate(shop.created_at)}</dd>
                    </div>
                    <div>
                      <dt className="text-muted">Equipo</dt>
                      <dd className="numeric">{shop.staff_count} profesionales</dd>
                    </div>
                    <div>
                      <dt className="text-muted">Turnos</dt>
                      <dd className="numeric">{shop.appointments_count}</dd>
                    </div>
                    <div>
                      <dt className="text-muted">Último turno</dt>
                      <dd className="numeric">{shortDate(shop.last_appointment_at)}</dd>
                    </div>
                    <div className="col-span-2">
                      <dt className="text-muted">Prueba gratuita</dt>
                      <dd className="numeric">
                        {shop.trial_ends_at
                          ? state === 'trial'
                            ? `vence ${shortDate(shop.trial_ends_at)} · ${trialDaysLeft(shop.trial_ends_at)} días`
                            : `venció ${shortDate(shop.trial_ends_at)}`
                          : 'sin prueba otorgada'}
                      </dd>
                    </div>
                  </dl>

                  {shop.suspension_note && (
                    <p className="mt-2 rounded-lg border border-base bg-surface-alt px-3 py-2 text-xs text-muted">
                      Motivo: {shop.suspension_note}
                    </p>
                  )}

                  <div className="mt-4 flex flex-wrap gap-2">
                    <button
                      type="button"
                      onClick={() => toggleSuspension(shop)}
                      disabled={busy}
                      className={`inline-flex min-h-[44px] flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 text-sm font-semibold disabled:opacity-60 ${
                        shop.is_suspended
                          ? 'border-strong bg-brand-primary text-white'
                          : 'border-base bg-surface text-expense hover:bg-expense-soft'
                      }`}
                    >
                      {shop.is_suspended ? (
                        <>
                          <CheckCircle2 size={16} aria-hidden="true" />
                          Habilitar
                        </>
                      ) : (
                        <>
                          <TriangleAlert size={16} aria-hidden="true" />
                          Suspender
                        </>
                      )}
                    </button>

                    <button
                      type="button"
                      onClick={() => grantTrial(shop)}
                      disabled={busy}
                      className="inline-flex min-h-[44px] flex-1 items-center justify-center gap-1.5 rounded-lg border border-base bg-surface-alt px-3 text-sm font-semibold text-ink hover:bg-surface disabled:opacity-60"
                    >
                      <CalendarPlus size={16} aria-hidden="true" />
                      90 días
                    </button>

                    {shop.trial_ends_at && (
                      <button
                        type="button"
                        onClick={() => clearTrial(shop)}
                        disabled={busy}
                        className="inline-flex min-h-[44px] items-center justify-center gap-1.5 rounded-lg border border-base bg-surface px-3 text-sm font-medium text-muted hover:bg-surface-alt disabled:opacity-60"
                      >
                        <Undo2 size={15} aria-hidden="true" />
                        Quitar prueba
                      </button>
                    )}
                  </div>

                  {busy && (
                    <p className="mt-2 flex items-center gap-1.5 text-xs text-muted">
                      <Loader2 size={13} className="animate-spin" aria-hidden="true" />
                      Aplicando…
                    </p>
                  )}
                </article>
              </li>
            )
          })}
        </ul>
      )}
    </main>
  )
}

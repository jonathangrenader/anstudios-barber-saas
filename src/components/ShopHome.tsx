import { useEffect, useState } from 'react'
import { listPendingAppointments } from '../lib/appointments'
import {
  BookOpen,
  CalendarClock,
  CalendarDays,
  LogOut,
  Settings,
  ShieldCheck,
  Users,
  Wallet,
} from 'lucide-react'
import { shopAccessState, trialDaysLeft } from '../lib/access'
import type { Shop } from '../types/shop'
import { useOfflineSync } from '../hooks/useOfflineSync'
import { AgendaScreen } from './AgendaScreen'
import { OfflineBanner } from './OfflineBanner'
import { CashScreen } from './CashScreen'
import { CatalogScreen } from './CatalogScreen'
import { ClientsScreen } from './ClientsScreen'
import { SettingsScreen } from './SettingsScreen'
import { StaffScreen } from './StaffScreen'

type View = 'agenda' | 'caja' | 'catalogo' | 'equipo' | 'clientes' | 'ajustes'

const TABS = [
  { id: 'agenda', label: 'Agenda', icon: CalendarDays },
  { id: 'caja', label: 'Caja', icon: Wallet },
  { id: 'catalogo', label: 'Catálogo', icon: BookOpen },
  { id: 'equipo', label: 'Equipo', icon: Users },
  { id: 'ajustes', label: 'Ajustes', icon: Settings },
] as const

export function ShopHome({
  shop,
  email,
  onSignOut,
  onShopUpdated,
  onOpenAdmin,
}: {
  shop: Shop
  email: string
  onSignOut: () => void
  onShopUpdated: (shop: Shop) => void
  onOpenAdmin?: () => void
}) {
  const [view, setView] = useState<View>('agenda')
  const [pendingCount, setPendingCount] = useState(0)
  const offline = useOfflineSync(shop.id)

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const rows = await listPendingAppointments(shop.id)
        if (!cancelled) setPendingCount(rows.length)
      } catch {
        if (!cancelled) setPendingCount(0)
      }
    }
    void load()
    const interval = window.setInterval(() => void load(), 60000)
    return () => {
      cancelled = true
      window.clearInterval(interval)
    }
  }, [shop.id])
  const trialActive = shopAccessState(shop) === 'trial' && Boolean(shop.trial_ends_at)

  return (
    <>
      <main className="mx-auto w-full max-w-md px-5 pb-28 pt-8">
        <header className="mb-6 flex items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-2.5">
            {shop.photo_url ? (
              <img
                src={shop.photo_url}
                alt=""
                className="size-10 shrink-0 rounded-lg border border-base object-cover"
              />
            ) : null}
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">
                ANSTUDIOS
              </p>
              <h1 className="truncate text-xl font-bold leading-tight">{shop.name}</h1>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {onOpenAdmin && (
              <button
                type="button"
                onClick={onOpenAdmin}
                aria-label="Panel de plataforma"
                className="inline-flex min-h-[44px] items-center justify-center rounded-lg border border-base bg-surface px-3 text-muted hover:bg-surface-alt"
              >
                <ShieldCheck size={16} aria-hidden="true" />
              </button>
            )}
            <button
              type="button"
              onClick={onSignOut}
              className="inline-flex min-h-[44px] items-center gap-2 rounded-lg border border-base bg-surface px-3 text-sm font-medium text-muted hover:bg-surface-alt"
            >
              <LogOut size={16} aria-hidden="true" />
              Salir
            </button>
          </div>
        </header>

        {trialActive && shop.trial_ends_at && (
          <div className="mb-4 flex items-start gap-2 rounded-lg border border-pending/40 bg-pending-soft px-3 py-2 text-xs text-pending">
            <CalendarClock size={15} className="mt-0.5 shrink-0" aria-hidden="true" />
            <p>
              <span className="font-semibold">Prueba gratuita</span> · vence el{' '}
              {new Intl.DateTimeFormat('es-AR', {
                day: '2-digit',
                month: '2-digit',
                year: 'numeric',
              }).format(new Date(shop.trial_ends_at))}{' '}
              ({trialDaysLeft(shop.trial_ends_at)} días).
            </p>
          </div>
        )}

        {pendingCount > 0 && (
          <button
            type="button"
            onClick={() => setView('agenda')}
            className="mb-4 flex w-full items-start gap-2 rounded-lg border border-pending/40 bg-pending-soft px-3 py-2 text-left text-xs text-pending"
          >
            <span className="font-semibold">Notificaciones:</span>
            <span className="flex-1">
              Tenés {pendingCount} turno{pendingCount === 1 ? '' : 's'} pendiente
              {pendingCount === 1 ? '' : 's'} de confirmación.
            </span>
            <span className="font-semibold underline underline-offset-4">Ver</span>
          </button>
        )}

        <OfflineBanner state={offline} onRetry={() => void offline.syncNow(true)} />

        {view === 'agenda' && (
          <AgendaScreen shop={shop} onOpenClients={() => setView('clientes')} />
        )}
        {view === 'caja' && <CashScreen shop={shop} online={offline.online} />}
        {view === 'clientes' && (
          <ClientsScreen
            shopId={shop.id}
            timezone={shop.timezone}
            onBack={() => setView('agenda')}
          />
        )}
        {view === 'catalogo' && <CatalogScreen shopId={shop.id} />}
        {view === 'equipo' && <StaffScreen shopId={shop.id} />}
        {view === 'ajustes' && (
          <SettingsScreen shop={shop} email={email} onShopUpdated={onShopUpdated} />
        )}
      </main>

      <nav
        aria-label="Secciones del local"
        className="fixed inset-x-0 bottom-0 z-40 border-t border-base bg-surface"
      >
        <div className="mx-auto grid w-full max-w-md grid-cols-5 gap-1 px-3 pb-[calc(0.5rem_+_env(safe-area-inset-bottom))] pt-2">
          {TABS.map((tab) => {
            const Icon = tab.icon
            const active = view === tab.id || (tab.id === 'agenda' && view === 'clientes')

            return (
              <button
                key={tab.id}
                type="button"
                onClick={() => setView(tab.id)}
                aria-current={active ? 'page' : undefined}
                className={`flex min-h-[44px] flex-col items-center justify-center gap-0.5 rounded-lg text-[11px] font-semibold transition-colors ${
                  active ? 'bg-surface-alt text-ink' : 'text-muted'
                }`}
              >
                <Icon size={18} aria-hidden="true" />
                {tab.label}
              </button>
            )
          })}
        </div>
      </nav>
    </>
  )
}

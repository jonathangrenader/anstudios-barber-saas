import { LogOut, LockKeyhole, Scissors } from 'lucide-react'
import type { ShopAccess } from '../types/shop'

function shortDate(iso: string): string {
  return new Intl.DateTimeFormat('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(new Date(iso))
}

export function BlockedShopScreen({
  shopName,
  access,
  email,
  onSignOut,
}: {
  shopName: string
  access: ShopAccess
  email?: string
  onSignOut: () => void
}) {
  const suspended = access.state === 'suspended'

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center gap-5 px-5 py-10">
      <header className="flex items-start gap-3">
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
          <Scissors size={22} strokeWidth={2} aria-hidden="true" />
        </span>
        <div className="min-w-0">
          <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">ANSTUDIOS</p>
          <h1 className="truncate text-xl font-bold leading-tight">{shopName}</h1>
          {email && <p className="truncate text-xs text-muted">{email}</p>}
        </div>
      </header>

      <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
        <span className="inline-flex items-center gap-2 rounded-md bg-expense-soft px-2 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-expense">
          <LockKeyhole size={14} aria-hidden="true" />
          {suspended ? 'Acceso suspendido' : 'Prueba vencida'}
        </span>

        <h2 className="mt-3 text-base font-semibold">
          {suspended ? 'Este local está suspendido' : 'La prueba gratuita terminó'}
        </h2>

        <p className="mt-1 text-sm text-muted">
          {suspended
            ? 'El acceso a la app, la agenda y las reservas online están pausados hasta que se active la licencia.'
            : access.trial_ends_at
              ? `La prueba terminó el ${shortDate(access.trial_ends_at)}. Para seguir usando la agenda y recibir reservas online necesitás activar la licencia.`
              : 'La prueba gratuita terminó. Para seguir usando la agenda y recibir reservas online necesitás activar la licencia.'}
        </p>

        {access.suspension_note && (
          <p className="mt-3 rounded-lg border border-base bg-surface-alt px-3 py-2 text-xs text-muted">
            Motivo: {access.suspension_note}
          </p>
        )}

        <p className="mt-4 text-sm">
          Escribinos a ANSTUDIOS para reactivar el acceso. Tus turnos, clientes y caja quedan
          guardados.
        </p>
      </section>

      <button
        type="button"
        onClick={onSignOut}
        className="inline-flex min-h-[44px] items-center justify-center gap-2 rounded-lg border border-base bg-surface px-4 text-sm font-medium text-muted hover:bg-surface-alt"
      >
        <LogOut size={16} aria-hidden="true" />
        Cerrar sesión
      </button>
    </main>
  )
}

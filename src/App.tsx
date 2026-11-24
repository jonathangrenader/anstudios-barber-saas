import { useEffect, useState } from 'react'
import { Loader2, Scissors } from 'lucide-react'
import { AuthScreen } from './components/AuthScreen'
import { BlockedShopScreen } from './components/BlockedShopScreen'
import { ManageBookingPage } from './components/ManageBookingPage'
import { PlatformAdminScreen } from './components/PlatformAdminScreen'
import { accessFromShop } from './lib/access'
import { OnboardingScreen } from './components/OnboardingScreen'
import { PublicBookingPage } from './components/PublicBookingPage'
import { ShopHome } from './components/ShopHome'
import { StaffHome } from './components/StaffHome'
import { Button } from './components/ui/controls'
import { useOnlineStatus } from './hooks/useOnlineStatus'
import { useSession } from './hooks/useSession'
import { useShop } from './hooks/useShop'
import { useStaffContext } from './hooks/useStaffContext'
import { usePlatformAdmin } from './hooks/usePlatformAdmin'

function Splash({ label }: { label: string }) {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-3 px-5">
      <span className="flex size-11 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
        <Scissors size={22} strokeWidth={2} aria-hidden="true" />
      </span>
      <p className="flex items-center gap-2 text-sm text-muted">
        <Loader2 size={15} className="animate-spin" aria-hidden="true" />
        {label}
      </p>
    </main>
  )
}

function ShopGate({
  userId,
  email,
  onSignOut,
  onOpenAdmin,
}: {
  userId: string
  email: string
  onSignOut: () => void
  onOpenAdmin?: () => void
}) {
  const { shop, loading, error, reload, adopt } = useShop(userId)
  const staff = useStaffContext()
  const online = useOnlineStatus()

  if (loading) return <Splash label="Cargando tu local…" />

  if (error) {
    return (
      <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center gap-4 px-5 py-10">
        <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
          <h1 className="text-base font-semibold">No pudimos cargar tu local</h1>
          <p className="mt-1 text-sm text-muted">{error}</p>
          <div className="mt-4">
            <Button type="button" variant="secondary" onClick={() => void reload()}>
              Reintentar
            </Button>
          </div>
        </section>
      </main>
    )
  }

  if (shop) {
    const access = accessFromShop(shop)
    if (access.state === 'suspended' || access.state === 'trial_expired') {
      return (
        <BlockedShopScreen
          shopName={shop.name}
          access={access}
          email={email}
          onSignOut={onSignOut}
        />
      )
    }

    return (
      <ShopHome
        shop={shop}
        email={email}
        onSignOut={onSignOut}
        onShopUpdated={adopt}
        onOpenAdmin={onOpenAdmin}
      />
    )
  }

  if (staff.loading) return <Splash label="Verificando tu acceso…" />

  if (staff.context) {
    const context = staff.context
    const access = context.shop_access
    if (access && (access.state === 'suspended' || access.state === 'trial_expired')) {
      return (
        <BlockedShopScreen
          shopName={context.shop_name}
          access={access}
          onSignOut={onSignOut}
        />
      )
    }

    return (
      <StaffHome
        context={context}
        online={online}
        onSignOut={onSignOut}
        onProfileSaved={(photoUrl, bio) =>
          staff.setContext({ ...context, staff_photo: photoUrl, staff_bio: bio })
        }
      />
    )
  }

  if (staff.error) {
    return (
      <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center gap-4 px-5 py-10">
        <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
          <h1 className="text-base font-semibold">No pudimos verificar tu acceso</h1>
          <p className="mt-1 text-sm text-muted">{staff.error}</p>
          <p className="mt-2 text-xs text-muted">
            Si te compartieron un código de profesional, reintentá cuando el local tenga la
            base actualizada.
          </p>
          <div className="mt-4">
            <Button type="button" variant="secondary" onClick={() => void staff.reload()}>
              Reintentar
            </Button>
          </div>
        </section>
      </main>
    )
  }

  return (
    <OnboardingScreen
      userId={userId}
      onCreated={adopt}
      onClaimed={staff.setContext}
      onSignOut={onSignOut}
    />
  )
}

function AuthenticatedApp() {
  const { session, loading, signOut } = useSession()
  const admin = usePlatformAdmin(session?.user.id ?? null)
  const [showShop, setShowShop] = useState(false)

  useEffect(() => {
    setShowShop(false)
  }, [session?.user.id])

  if (loading) return <Splash label="Verificando sesión…" />
  if (!session) return <AuthScreen />
  if (admin.loading) return <Splash label="Verificando acceso…" />

  if (admin.is_admin && !showShop) {
    return (
      <PlatformAdminScreen
        email={session.user.email ?? ''}
        hasShop={admin.has_shop}
        onOpenShop={() => setShowShop(true)}
        onSignOut={() => void signOut()}
      />
    )
  }

  return (
    <ShopGate
      key={session.user.id}
      userId={session.user.id}
      email={session.user.email ?? ''}
      onSignOut={() => void signOut()}
      onOpenAdmin={admin.is_admin ? () => setShowShop(false) : undefined}
    />
  )
}

/** `/r/:slug` se resuelve sin router para no cargar el flujo autenticado. */
function publicSlugFromPath(pathname: string): string | null {
  if (pathname === '/r' || pathname === '/r/') return ''
  if (!pathname.startsWith('/r/')) return null

  const rest = pathname.slice(3).replace(/\/+$/, '')
  if (!rest || rest.includes('/')) return ''

  try {
    return decodeURIComponent(rest)
  } catch {
    return rest
  }
}

/** `/turno/:token` es el link privado que recibe el cliente para gestionar su reserva. */
function publicTokenFromPath(pathname: string): string | null {
  if (!pathname.startsWith('/turno/')) return null

  const rest = pathname.slice(7).replace(/\/+$/, '')
  if (!rest || rest.includes('/')) return ''

  try {
    return decodeURIComponent(rest)
  } catch {
    return rest
  }
}

export default function App() {
  const token = publicTokenFromPath(window.location.pathname)
  if (token !== null) return <ManageBookingPage token={token} />

  const slug = publicSlugFromPath(window.location.pathname)
  if (slug !== null) return <PublicBookingPage slug={slug} />

  return <AuthenticatedApp />
}

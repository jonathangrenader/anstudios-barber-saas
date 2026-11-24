import { useState, type FormEvent } from 'react'
import { ArrowLeft, KeyRound, Store } from 'lucide-react'
import { createShop, normalizeSlug, SLUG_PATTERN } from '../lib/shops'
import { claimStaffInvite } from '../lib/staff'
import { argentinaTimezones, DEFAULT_TIMEZONE, timezoneLabel } from '../lib/timezones'
import type { Shop, ShopInput } from '../types/shop'
import type { StaffContext } from '../types/staff'
import { Combobox, type ComboboxOption } from './ui/Combobox'
import { Button, FieldError, Input, Select } from './ui/controls'

const SLOT_OPTIONS = [15, 20, 30, 45, 60, 90, 120]

const TIMEZONE_OPTIONS: ComboboxOption[] = argentinaTimezones().map((zone) => ({
  value: zone,
  label: timezoneLabel(zone),
}))

type FieldErrors = Partial<Record<keyof ShopInput | 'form', string>>

export function OnboardingScreen({
  userId,
  onCreated,
  onClaimed,
  onSignOut,
}: {
  userId: string
  onCreated: (shop: Shop) => void
  onClaimed: (context: StaffContext) => void
  onSignOut: () => void
}) {
  const [name, setName] = useState('')
  const [slug, setSlug] = useState('')
  const [slugEdited, setSlugEdited] = useState(false)
  const [phone, setPhone] = useState('')
  const [address, setAddress] = useState('')
  const [timezone, setTimezone] = useState(DEFAULT_TIMEZONE)
  const [openTime, setOpenTime] = useState('09:00')
  const [closeTime, setCloseTime] = useState('21:00')
  const [slotDuration, setSlotDuration] = useState(30)
  const [pending, setPending] = useState(false)
  const [errors, setErrors] = useState<FieldErrors>({})
  const [entry, setEntry] = useState<'choose' | 'shop' | 'claim'>('choose')
  const [claimCode, setClaimCode] = useState('')
  const [claimPending, setClaimPending] = useState(false)
  const [claimError, setClaimError] = useState<string | null>(null)

  const normalizedSlug = normalizeSlug(slug)

  function handleNameChange(value: string) {
    setName(value)
    if (!slugEdited) setSlug(normalizeSlug(value))
  }

  function handleSlugChange(value: string) {
    setSlugEdited(true)
    setSlug(value.toLowerCase().replace(/\s+/g, '-'))
  }

  function validate(): FieldErrors {
    const next: FieldErrors = {}
    const trimmedName = name.trim()

    if (trimmedName.length < 2 || trimmedName.length > 80) {
      next.name = 'El nombre debe tener entre 2 y 80 caracteres.'
    }
    if (!SLUG_PATTERN.test(normalizedSlug)) {
      next.slug = 'El link debe tener entre 3 y 60 caracteres: minúsculas, números y guiones.'
    }
    if (phone.trim().length > 30) {
      next.phone = 'El teléfono no puede superar los 30 caracteres.'
    }
    if (address.trim().length > 120) {
      next.address = 'La dirección no puede superar los 120 caracteres.'
    }
    if (!openTime || !closeTime) {
      next.open_time = 'Indicá el horario de apertura y cierre.'
    } else if (closeTime <= openTime) {
      next.close_time = 'El cierre debe ser posterior a la apertura.'
    }
    if (slotDuration < 10 || slotDuration > 120) {
      next.slot_duration_min = 'La duración debe estar entre 10 y 120 minutos.'
    }

    return next
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const nextErrors = validate()
    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    setPending(true)
    try {
      const shop = await createShop(userId, {
        name: name.trim(),
        slug: normalizedSlug,
        phone: phone.trim() || null,
        address: address.trim() || null,
        timezone,
        open_time: openTime,
        close_time: closeTime,
        slot_duration_min: slotDuration,
      })
      onCreated(shop)
    } catch (err) {
      setErrors({ form: err instanceof Error ? err.message : 'No pudimos crear el local.' })
    } finally {
      setPending(false)
    }
  }

  async function handleClaim(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const normalized = claimCode.replace(/[^a-zA-Z0-9]/g, '').toUpperCase()

    if (normalized.length !== 8) {
      setClaimError('El código tiene 8 caracteres. Revisalo e intentá de nuevo.')
      return
    }

    setClaimPending(true)
    setClaimError(null)
    try {
      onClaimed(await claimStaffInvite(normalized))
    } catch (err) {
      setClaimError(
        err instanceof Error ? err.message : 'No pudimos validar el código.',
      )
    } finally {
      setClaimPending(false)
    }
  }

  if (entry === 'choose') {
    return (
      <main className="mx-auto w-full max-w-md px-5 py-8">
        <header className="mb-6 flex items-start gap-3">
          <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
            <Store size={22} strokeWidth={2} aria-hidden="true" />
          </span>
          <div>
            <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">
              ANSTUDIOS
            </p>
            <h1 className="text-xl font-bold leading-tight">¿Cómo vas a usar la app?</h1>
            <p className="mt-1 text-sm text-muted">
              Elegí una opción para continuar con esta cuenta.
            </p>
          </div>
        </header>

        <div className="space-y-3">
          <button
            type="button"
            onClick={() => setEntry('shop')}
            className="flex min-h-[44px] w-full items-start gap-3 rounded-xl border border-base bg-surface p-4 text-left transition-colors hover:bg-surface-alt"
          >
            <Store size={20} className="mt-0.5 shrink-0" aria-hidden="true" />
            <span>
              <span className="block text-sm font-semibold">Tengo un local</span>
              <span className="mt-0.5 block text-xs text-muted">
                Crear el local, el catálogo y el equipo.
              </span>
            </span>
          </button>

          <button
            type="button"
            onClick={() => setEntry('claim')}
            className="flex min-h-[44px] w-full items-start gap-3 rounded-xl border border-base bg-surface p-4 text-left transition-colors hover:bg-surface-alt"
          >
            <KeyRound size={20} className="mt-0.5 shrink-0" aria-hidden="true" />
            <span>
              <span className="block text-sm font-semibold">Soy profesional</span>
              <span className="mt-0.5 block text-xs text-muted">
                Tengo el código de acceso de mi local.
              </span>
            </span>
          </button>
        </div>

        <button
          type="button"
          onClick={onSignOut}
          className="mt-6 min-h-[44px] w-full text-sm font-medium text-muted underline-offset-4 hover:underline"
        >
          Cerrar sesión
        </button>
      </main>
    )
  }

  return (
    <main className="mx-auto w-full max-w-md px-5 py-8">
      <button
        type="button"
        onClick={() => {
          setEntry('choose')
          setClaimCode('')
          setClaimError(null)
        }}
        className="mb-4 inline-flex min-h-[44px] items-center gap-1.5 text-sm font-medium text-muted hover:text-ink"
      >
        <ArrowLeft size={16} aria-hidden="true" />
        Volver
      </button>

      <header className="mb-6 flex items-start gap-3">
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
          {entry === 'claim' ? (
            <KeyRound size={22} strokeWidth={2} aria-hidden="true" />
          ) : (
            <Store size={22} strokeWidth={2} aria-hidden="true" />
          )}
        </span>
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">
            {entry === 'claim' ? 'Acceso de profesional' : 'Paso 1 de 1'}
          </p>
          <h1 className="text-xl font-bold leading-tight">
            {entry === 'claim' ? 'Vinculá tu cuenta' : 'Configurá tu local'}
          </h1>
          <p className="mt-1 text-sm text-muted">
            {entry === 'claim'
              ? 'Ingresá el código de 8 caracteres que te dio el local. Vas a ver solo tu agenda.'
              : 'Estos datos definen tu link público y la grilla de turnos.'}
          </p>
        </div>
      </header>

      {entry === 'shop' && (
      <form onSubmit={handleSubmit} className="space-y-5" noValidate>
        <fieldset className="space-y-4 rounded-xl border border-base bg-surface p-4 sm:p-5">
          <legend className="px-1 text-xs font-semibold uppercase tracking-[0.12em] text-muted">
            Identidad
          </legend>

          <div className="space-y-1.5">
            <label htmlFor="shop-name" className="text-sm font-medium">
              Nombre del local
            </label>
            <Input
              id="shop-name"
              value={name}
              onChange={(event) => handleNameChange(event.target.value)}
              placeholder="Barbería El Roble"
              autoComplete="organization"
              aria-invalid={Boolean(errors.name)}
            />
            <FieldError>{errors.name ?? null}</FieldError>
          </div>

          <div className="space-y-1.5">
            <label htmlFor="shop-slug" className="text-sm font-medium">
              Link público
            </label>
            <div className="flex items-center gap-2">
              <span className="shrink-0 font-mono text-xs text-muted">/r/</span>
              <Input
                id="shop-slug"
                value={slug}
                onChange={(event) => handleSlugChange(event.target.value)}
                onBlur={() => setSlug(normalizeSlug(slug))}
                placeholder="barberia-el-roble"
                autoCapitalize="none"
                autoCorrect="off"
                spellCheck={false}
                className="font-mono text-xs"
                aria-invalid={Boolean(errors.slug)}
              />
            </div>
            <p className="text-xs text-muted">
              Solo minúsculas, números y guiones. Se usa para compartir la reserva.
            </p>
            <FieldError>{errors.slug ?? null}</FieldError>
          </div>
        </fieldset>

        <fieldset className="space-y-4 rounded-xl border border-base bg-surface p-4 sm:p-5">
          <legend className="px-1 text-xs font-semibold uppercase tracking-[0.12em] text-muted">
            Contacto
          </legend>

          <div className="space-y-1.5">
            <label htmlFor="shop-phone" className="text-sm font-medium">
              Teléfono <span className="font-normal text-muted">(opcional)</span>
            </label>
            <Input
              id="shop-phone"
              type="tel"
              inputMode="tel"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
              placeholder="11 5555 5555"
              autoComplete="tel"
              aria-invalid={Boolean(errors.phone)}
            />
            <FieldError>{errors.phone ?? null}</FieldError>
          </div>

          <div className="space-y-1.5">
            <label htmlFor="shop-address" className="text-sm font-medium">
              Dirección <span className="font-normal text-muted">(opcional)</span>
            </label>
            <Input
              id="shop-address"
              value={address}
              onChange={(event) => setAddress(event.target.value)}
              placeholder="Av. Rivadavia 1234, CABA"
              autoComplete="street-address"
              aria-invalid={Boolean(errors.address)}
            />
            <FieldError>{errors.address ?? null}</FieldError>
          </div>
        </fieldset>

        <fieldset className="space-y-4 rounded-xl border border-base bg-surface p-4 sm:p-5">
          <legend className="px-1 text-xs font-semibold uppercase tracking-[0.12em] text-muted">
            Horarios
          </legend>

          <div className="space-y-1.5">
            <label htmlFor="shop-timezone" className="text-sm font-medium">
              Zona horaria
            </label>
            <Combobox
              id="shop-timezone"
              value={timezone}
              options={TIMEZONE_OPTIONS}
              onChange={setTimezone}
              placeholder="Buscar zona horaria…"
            />
            <p className="text-xs text-muted">
              Escribí para filtrar; al enfocar ves todas las zonas de Argentina.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1.5">
              <label htmlFor="shop-open" className="text-sm font-medium">
                Apertura
              </label>
              <Input
                id="shop-open"
                type="time"
                step={300}
                value={openTime}
                onChange={(event) => setOpenTime(event.target.value)}
                className="numeric"
                aria-invalid={Boolean(errors.open_time)}
              />
            </div>
            <div className="space-y-1.5">
              <label htmlFor="shop-close" className="text-sm font-medium">
                Cierre
              </label>
              <Input
                id="shop-close"
                type="time"
                step={300}
                value={closeTime}
                onChange={(event) => setCloseTime(event.target.value)}
                className="numeric"
                aria-invalid={Boolean(errors.close_time)}
              />
            </div>
          </div>
          <FieldError>{errors.open_time ?? errors.close_time ?? null}</FieldError>

          <div className="space-y-1.5">
            <label htmlFor="shop-slot" className="text-sm font-medium">
              Duración base de turno
            </label>
            <Select
              id="shop-slot"
              value={slotDuration}
              onChange={(event) => setSlotDuration(Number(event.target.value))}
            >
              {SLOT_OPTIONS.map((minutes) => (
                <option key={minutes} value={minutes}>
                  {minutes} minutos
                </option>
              ))}
            </Select>
            <p className="text-xs text-muted">
              Cada servicio puede tener su propia duración; esta es la grilla general.
            </p>
            <FieldError>{errors.slot_duration_min ?? null}</FieldError>
          </div>
        </fieldset>

        <FieldError>{errors.form ?? null}</FieldError>

        <div className="space-y-2">
          <Button type="submit" loading={pending}>
            Crear local
          </Button>
          <button
            type="button"
            onClick={onSignOut}
            className="min-h-[44px] w-full text-sm font-medium text-muted underline-offset-4 hover:underline"
          >
            Cerrar sesión
          </button>
        </div>
      </form>
      )}

      {entry === 'claim' && (
        <section aria-labelledby="claim-heading" className="space-y-3">
          <form onSubmit={handleClaim} className="space-y-3" noValidate>
            <div className="space-y-1.5">
              <label htmlFor="claim-code" className="text-sm font-medium">
                Código de 8 caracteres
              </label>
              <Input
                id="claim-code"
                value={claimCode}
                onChange={(event) => setClaimCode(event.target.value.toUpperCase())}
                placeholder="A1B2-C3D4"
                autoCapitalize="characters"
                autoCorrect="off"
                spellCheck={false}
                maxLength={12}
                className="numeric font-mono tracking-[0.16em]"
                aria-invalid={Boolean(claimError)}
              />
              <FieldError>{claimError}</FieldError>
            </div>

            <Button type="submit" loading={claimPending}>
              Vincular mi cuenta
            </Button>
          </form>

          <p className="text-xs text-muted">
            ¿Todavía no tenés el código? Pedíselo al dueño del local desde Equipo.
          </p>
        </section>
      )}
    </main>
  )
}

import { useId, useState, type FormEvent } from 'react'
import {
  Check,
  Clock,
  Copy,
  ExternalLink,
  Link2,
  MapPin,
  Moon,
  Phone,
  Store,
  Sun,
  Type,
} from 'lucide-react'
import { mapsHref, updateShop } from '../lib/shops'
import type { Shop, ShopInput } from '../types/shop'
import { usePreferences, type TextSize, type Theme } from './PreferencesProvider'
import { Button, FieldError, Input, Select, Textarea } from './ui/controls'
import { PhotoPicker } from './ui/PhotoPicker'

const SLOT_OPTIONS = [15, 20, 30, 45, 60, 90, 120]

const TEXT_SIZES: { id: TextSize; label: string; sample: string }[] = [
  { id: 'compact', label: 'Compacta', sample: 'A' },
  { id: 'normal', label: 'Normal', sample: 'A' },
  { id: 'large', label: 'Grande', sample: 'A' },
]

const THEMES: { id: Theme; label: string; icon: typeof Sun }[] = [
  { id: 'light', label: 'Claro', icon: Sun },
  { id: 'dark', label: 'Oscuro', icon: Moon },
]

interface ShopForm {
  name: string
  description: string
  address: string
  maps_url: string
  phone_landline: string
  phone_mobile: string
  whatsapp: string
  photo_url: string | null
  open_time: string
  close_time: string
  slot_duration_min: number
  professional_booking_mode: 'disabled' | 'per_staff' | 'all'
  public_booking_enabled: boolean
  professionals_can_manage_appointments: boolean
}

function toForm(shop: Shop): ShopForm {
  return {
    name: shop.name,
    description: shop.description ?? '',
    address: shop.address ?? '',
    maps_url: shop.maps_url ?? '',
    phone_landline: shop.phone_landline ?? '',
    phone_mobile: shop.phone_mobile ?? '',
    whatsapp: shop.whatsapp ?? '',
    photo_url: shop.photo_url,
    open_time: shop.open_time.slice(0, 5),
    close_time: shop.close_time.slice(0, 5),
    slot_duration_min: shop.slot_duration_min,
    professional_booking_mode: shop.professional_booking_mode,
    public_booking_enabled: shop.public_booking_enabled,
    professionals_can_manage_appointments: shop.professionals_can_manage_appointments,
  }
}

function Section({
  title,
  description,
  children,
}: {
  title: string
  description?: string
  children: React.ReactNode
}) {
  return (
    <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
      <h2 className="text-base font-bold">{title}</h2>
      {description && <p className="mt-0.5 text-xs text-muted">{description}</p>}
      <div className="mt-4">{children}</div>
    </section>
  )
}

export function SettingsScreen({
  shop,
  email,
  onShopUpdated,
}: {
  shop: Shop
  email: string
  onShopUpdated: (shop: Shop) => void
}) {
  const formId = useId()
  const { theme, setTheme, textSize, setTextSize } = usePreferences()
  const [form, setForm] = useState<ShopForm>(() => toForm(shop))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [copied, setCopied] = useState(false)

  const publicUrl = `${window.location.origin}/r/${shop.slug}`
  const maps = mapsHref(shop)

  function set<K extends keyof ShopForm>(key: K, value: ShopForm[K]) {
    setForm((current) => ({ ...current, [key]: value }))
    setSaved(false)
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const name = form.name.trim()
    if (name.length < 2 || name.length > 80) {
      setError('El nombre debe tener entre 2 y 80 caracteres.')
      return
    }
    if (form.description.trim().length > 600) {
      setError('La descripción admite hasta 600 caracteres.')
      return
    }
    if (form.maps_url.trim() && !/^https?:\/\//i.test(form.maps_url.trim())) {
      setError('El link de Maps debe empezar con http:// o https://.')
      return
    }

    const whatsapp = form.whatsapp.trim() || null
    const mobile = form.phone_mobile.trim() || null
    const landline = form.phone_landline.trim() || null

    const patch: Partial<ShopInput> = {
      name,
      description: form.description.trim() || null,
      address: form.address.trim() || null,
      maps_url: form.maps_url.trim() || null,
      whatsapp,
      phone_mobile: mobile,
      phone_landline: landline,
      phone: whatsapp ?? mobile ?? landline,
      photo_url: form.photo_url,
      open_time: form.open_time,
      close_time: form.close_time,
      slot_duration_min: form.slot_duration_min,
      professional_booking_mode: form.professional_booking_mode,
      public_booking_enabled: form.public_booking_enabled,
      professionals_can_manage_appointments: form.professionals_can_manage_appointments,
    }

    setSaving(true)
    setError(null)
    try {
      const updated = await updateShop(shop.id, shop.owner_id, patch)
      onShopUpdated(updated)
      setForm(toForm(updated))
      setSaved(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos guardar los cambios.')
    } finally {
      setSaving(false)
    }
  }

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(publicUrl)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } catch {
      window.prompt('Copiá el link del local', publicUrl)
    }
  }

  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-lg font-bold">Ajustes del salón</h1>
        <p className="mt-0.5 text-xs text-muted">
          Datos que ven tus clientes y preferencias de esta pantalla.
        </p>
      </div>

      <form id={formId} onSubmit={(event) => void handleSubmit(event)} className="space-y-3">
        <Section
          title="Perfil del salón"
          description="Nombre, foto y una descripción breve para el link público."
        >
          <div className="space-y-4">
            <PhotoPicker
              label="Foto del salón"
              prefix={`shops/${shop.id}`}
              value={form.photo_url}
              onChange={(url) => set('photo_url', url)}
              disabled={saving}
            />

            <div>
              <label htmlFor={`${formId}-name`} className="text-xs font-medium text-muted">
                Nombre
              </label>
              <Input
                id={`${formId}-name`}
                value={form.name}
                maxLength={80}
                required
                onChange={(event) => set('name', event.target.value)}
                className="mt-1.5"
              />
            </div>

            <div>
              <label htmlFor={`${formId}-description`} className="text-xs font-medium text-muted">
                Descripción
              </label>
              <Textarea
                id={`${formId}-description`}
                value={form.description}
                maxLength={600}
                rows={3}
                placeholder="Contá qué hace especial al salón."
                onChange={(event) => set('description', event.target.value)}
                className="mt-1.5"
              />
              <p className="numeric mt-1 text-right text-[11px] text-muted">
                {form.description.length}/600
              </p>
            </div>
          </div>
        </Section>

        <Section title="Contacto y ubicación" description="Se muestran en la reserva online.">
          <div className="space-y-4">
            <div>
              <label htmlFor={`${formId}-address`} className="text-xs font-medium text-muted">
                Dirección
              </label>
              <div className="relative mt-1.5">
                <MapPin
                  size={15}
                  className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted"
                  aria-hidden="true"
                />
                <Input
                  id={`${formId}-address`}
                  value={form.address}
                  maxLength={200}
                  placeholder="Av. Corrientes 1234, CABA"
                  onChange={(event) => set('address', event.target.value)}
                  className="pl-9"
                />
              </div>
            </div>

            <div>
              <label htmlFor={`${formId}-maps`} className="text-xs font-medium text-muted">
                Link de Google Maps
              </label>
              <Input
                id={`${formId}-maps`}
                type="url"
                inputMode="url"
                value={form.maps_url}
                maxLength={500}
                placeholder="https://maps.google.com/…"
                onChange={(event) => set('maps_url', event.target.value)}
                className="mt-1.5"
              />
              <p className="mt-1 text-[11px] text-muted">
                Si lo dejás vacío, usamos la dirección para abrir Maps.
              </p>
            </div>

            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <div>
                <label htmlFor={`${formId}-whatsapp`} className="text-xs font-medium text-muted">
                  WhatsApp
                </label>
                <div className="relative mt-1.5">
                  <Phone
                    size={15}
                    className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted"
                    aria-hidden="true"
                  />
                  <Input
                    id={`${formId}-whatsapp`}
                    type="tel"
                    inputMode="tel"
                    value={form.whatsapp}
                    maxLength={20}
                    placeholder="11 2345 6789"
                    onChange={(event) => set('whatsapp', event.target.value)}
                    className="numeric pl-9"
                  />
                </div>
              </div>
              <div>
                <label htmlFor={`${formId}-mobile`} className="text-xs font-medium text-muted">
                  Celular
                </label>
                <Input
                  id={`${formId}-mobile`}
                  type="tel"
                  inputMode="tel"
                  value={form.phone_mobile}
                  maxLength={20}
                  onChange={(event) => set('phone_mobile', event.target.value)}
                  className="numeric mt-1.5"
                />
              </div>
              <div>
                <label htmlFor={`${formId}-landline`} className="text-xs font-medium text-muted">
                  Teléfono fijo
                </label>
                <Input
                  id={`${formId}-landline`}
                  type="tel"
                  inputMode="tel"
                  value={form.phone_landline}
                  maxLength={20}
                  onChange={(event) => set('phone_landline', event.target.value)}
                  className="numeric mt-1.5"
                />
              </div>
            </div>

            {maps && (
              <a
                href={maps}
                target="_blank"
                rel="noreferrer"
                className="inline-flex min-h-[44px] items-center gap-1.5 text-xs font-semibold text-ink underline decoration-base underline-offset-4 hover:decoration-strong"
              >
                <ExternalLink size={13} aria-hidden="true" />
                Ver la ubicación en Maps
              </a>
            )}
          </div>
        </Section>

        <Section title="Horario de atención" description="Define la grilla de turnos del local.">
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label htmlFor={`${formId}-open`} className="text-xs font-medium text-muted">
                Abre
              </label>
              <Input
                id={`${formId}-open`}
                type="time"
                value={form.open_time}
                required
                onChange={(event) => set('open_time', event.target.value)}
                className="numeric mt-1.5"
              />
            </div>
            <div>
              <label htmlFor={`${formId}-close`} className="text-xs font-medium text-muted">
                Cierra
              </label>
              <Input
                id={`${formId}-close`}
                type="time"
                value={form.close_time}
                required
                onChange={(event) => set('close_time', event.target.value)}
                className="numeric mt-1.5"
              />
            </div>
          </div>
          <div className="mt-3">
            <label htmlFor={`${formId}-slot`} className="text-xs font-medium text-muted">
              Duración base de turno
            </label>
            <Select
              id={`${formId}-slot`}
              value={form.slot_duration_min}
              onChange={(event) => set('slot_duration_min', Number(event.target.value))}
              className="mt-1.5"
            >
              {SLOT_OPTIONS.map((minutes) => (
                <option key={minutes} value={minutes}>
                  {minutes} minutos
                </option>
              ))}
            </Select>
          </div>
        </Section>

        <Section
          title="Equipo y permisos"
          description="Controlá quién puede agendar turnos para los profesionales."
        >
          <div className="space-y-3">
            <div>
              <p className="text-xs font-medium text-muted">Modo de agendado por profesionales</p>
              <div className="mt-1.5 grid grid-cols-3 gap-1.5" role="group" aria-label="Modo de agendado por profesionales">
                {([
                  { value: 'disabled', label: 'Solo local' },
                  { value: 'per_staff', label: 'Por profesional' },
                  { value: 'all', label: 'Todos' },
                ] as const).map((option) => {
                  const active = form.professional_booking_mode === option.value
                  return (
                    <button
                      key={option.value}
                      type="button"
                      aria-pressed={active}
                      onClick={() => set('professional_booking_mode', option.value)}
                      disabled={saving}
                      className={`min-h-[44px] rounded-lg border px-2 text-xs font-semibold ${
                        active
                          ? 'border-strong bg-surface-alt text-ink'
                          : 'border-base bg-surface text-muted hover:bg-surface-alt'
                      }`}
                    >
                      {option.label}
                    </button>
                  )
                })}
              </div>
              <p className="mt-1.5 text-[11px] text-muted">
                “Solo local”: solo el dueño agenda. “Por profesional”: se define en cada
                ficha de Equipo. “Todos”: todos los profesionales pueden agendar.
              </p>
            </div>

            <label className="flex items-start gap-3 rounded-lg border border-base bg-surface-alt/40 px-3 py-3">
              <input
                type="checkbox"
                checked={form.public_booking_enabled}
                onChange={(event) => set('public_booking_enabled', event.target.checked)}
                className="mt-0.5 size-5 shrink-0 accent-brand-primary"
                disabled={saving}
              />
              <span className="min-w-0">
                <span className="block text-sm font-semibold text-ink">
                  Permitir reservas públicas (link)
                </span>
                <span className="mt-0.5 block text-xs text-muted">
                  Si está activo, los clientes pueden entrar al link del local, elegir
                  servicio y profesional y reservar turno. Si está desactivado, el link
                  no permite reservar.
                </span>
              </span>
            </label>

            <label className="flex items-start gap-3 rounded-lg border border-base bg-surface-alt/40 px-3 py-3">
              <input
                type="checkbox"
                checked={form.professionals_can_manage_appointments}
                onChange={(event) => set('professionals_can_manage_appointments', event.target.checked)}
                className="mt-0.5 size-5 shrink-0 accent-brand-primary"
                disabled={saving}
              />
              <span className="min-w-0">
                <span className="block text-sm font-semibold text-ink">
                  Permitir a profesionales gestionar turnos
                </span>
                <span className="mt-0.5 block text-xs text-muted">
                  Si está activo, los profesionales pueden reasignar un turno a otro
                  profesional o reprogramarlo, y avisar al cliente. Si está desactivado,
                  solo el dueño puede hacerlo.
                </span>
              </span>
            </label>
          </div>
        </Section>

        <FieldError>{error}</FieldError>

        {saved && (
          <p
            role="status"
            className="flex items-center gap-1.5 rounded-lg border border-income/30 bg-income-soft px-3 py-2 text-xs font-semibold text-income"
          >
            <Check size={14} aria-hidden="true" />
            Cambios guardados.
          </p>
        )}

        <Button type="submit" loading={saving}>
          Guardar cambios
        </Button>
      </form>

      <Section title="Link público" description="Es el link que compartís con tus clientes.">
        <div className="flex items-center gap-2 rounded-lg border border-base bg-surface-alt px-3 py-2">
          <Link2 size={15} className="shrink-0 text-muted" aria-hidden="true" />
          <span className="min-w-0 flex-1 break-all font-mono text-xs">{publicUrl}</span>
        </div>
        <div className="mt-2 grid grid-cols-2 gap-1.5">
          <button
            type="button"
            onClick={() => void copyLink()}
            className="inline-flex min-h-[44px] items-center justify-center gap-1.5 rounded-lg border border-base bg-surface px-3 text-xs font-semibold hover:bg-surface-alt"
          >
            {copied ? <Check size={14} aria-hidden="true" /> : <Copy size={14} aria-hidden="true" />}
            {copied ? 'Copiado' : 'Copiar link'}
          </button>
          <a
            href={`/r/${shop.slug}`}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-[44px] items-center justify-center gap-1.5 rounded-lg border border-base bg-surface px-3 text-xs font-semibold hover:bg-surface-alt"
          >
            <ExternalLink size={14} aria-hidden="true" />
            Abrir reserva
          </a>
        </div>
      </Section>

      <Section title="Apariencia" description="Se guarda en este dispositivo.">
        <div className="space-y-4">
          <div>
            <p className="flex items-center gap-1.5 text-xs font-medium text-muted">
              <Type size={14} aria-hidden="true" />
              Tamaño de letra
            </p>
            <div className="mt-1.5 grid grid-cols-3 gap-1.5" role="group" aria-label="Tamaño de letra">
              {TEXT_SIZES.map((option) => {
                const active = textSize === option.id
                return (
                  <button
                    key={option.id}
                    type="button"
                    aria-pressed={active}
                    onClick={() => setTextSize(option.id)}
                    className={`flex min-h-[44px] flex-col items-center justify-center rounded-lg border px-1 ${
                      active
                        ? 'border-strong bg-surface-alt'
                        : 'border-base bg-surface hover:bg-surface-alt'
                    }`}
                  >
                    <span
                      aria-hidden="true"
                      className={
                        option.id === 'compact'
                          ? 'text-sm font-bold leading-none'
                          : option.id === 'large'
                            ? 'text-xl font-bold leading-none'
                            : 'text-base font-bold leading-none'
                      }
                    >
                      {option.sample}
                    </span>
                    <span className="mt-1 text-[10px] font-semibold text-muted">
                      {option.label}
                    </span>
                  </button>
                )
              })}
            </div>
          </div>

          <div>
            <p className="flex items-center gap-1.5 text-xs font-medium text-muted">
              <Moon size={14} aria-hidden="true" />
              Tema
            </p>
            <div className="mt-1.5 grid grid-cols-2 gap-1.5" role="group" aria-label="Tema">
              {THEMES.map((option) => {
                const Icon = option.icon
                const active = theme === option.id
                return (
                  <button
                    key={option.id}
                    type="button"
                    aria-pressed={active}
                    onClick={() => setTheme(option.id)}
                    className={`inline-flex min-h-[44px] items-center justify-center gap-2 rounded-lg border text-sm font-semibold ${
                      active
                        ? 'border-strong bg-surface-alt'
                        : 'border-base bg-surface hover:bg-surface-alt'
                    }`}
                  >
                    <Icon size={16} aria-hidden="true" />
                    {option.label}
                  </button>
                )
              })}
            </div>
          </div>
        </div>
      </Section>

      <Section title="Sesión">
        <p className="text-xs text-muted">
          Cuenta: <span className="break-all text-ink">{email}</span>
        </p>
        <p className="mt-2 flex items-start gap-1.5 text-[11px] text-muted">
          <Store size={13} className="mt-0.5 shrink-0" aria-hidden="true" />
          El link público, el horario y los datos de contacto se actualizan al guardar. Los
          cambios de apariencia no afectan a tus clientes.
        </p>
      </Section>

      <p className="flex items-center gap-1.5 px-1 text-[11px] text-muted">
        <Clock size={12} aria-hidden="true" />
        Zona horaria del local: {shop.timezone}
      </p>
    </div>
  )
}

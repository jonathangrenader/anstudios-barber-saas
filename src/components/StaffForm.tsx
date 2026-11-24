import { useState, type FormEvent } from 'react'
import type { StaffInput, StaffMember } from '../types/staff'
import { Button, Checkbox, FieldError, Input } from './ui/controls'

type FieldErrors = Partial<Record<'name' | 'phone' | 'commission' | 'productCommission', string>>

function parseNumber(raw: string): number {
  return Number(raw.trim().replace(',', '.'))
}

function round2(value: number): number {
  return Math.round(value * 100) / 100
}

export function StaffForm({
  member,
  pending,
  error,
  onSubmit,
  onCancel,
}: {
  member: StaffMember | null
  pending: boolean
  error: string | null
  onSubmit: (input: StaffInput) => void
  onCancel: () => void
}) {
  const [name, setName] = useState(member?.name ?? '')
  const [role, setRole] = useState(member?.role ?? 'Profesional')
  const [phone, setPhone] = useState(member?.phone ?? '')
  const [commission, setCommission] = useState(
    member ? String(member.commission_pct) : '50',
  )
  const [productCommission, setProductCommission] = useState(
    member ? String(member.product_commission_pct) : '10',
  )
  const [color, setColor] = useState(member?.color_hex ?? '#1E3A2F')
  const [isActive, setIsActive] = useState(member?.is_active ?? true)
  const [canBook, setCanBook] = useState(member?.can_book_appointments ?? false)
  const [errors, setErrors] = useState<FieldErrors>({})

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    const trimmedName = name.trim()
    const commissionValue = parseNumber(commission)
    const productCommissionValue = parseNumber(productCommission)

    if (trimmedName.length < 2 || trimmedName.length > 80) {
      nextErrors.name = 'El nombre debe tener entre 2 y 80 caracteres.'
    }
    if (phone.trim().length > 30) {
      nextErrors.phone = 'El teléfono no puede superar los 30 caracteres.'
    }
    if (!Number.isFinite(commissionValue) || commissionValue < 0 || commissionValue > 100) {
      nextErrors.commission = 'La comisión de servicios debe estar entre 0 y 100.'
    }
    if (
      !Number.isFinite(productCommissionValue) ||
      productCommissionValue < 0 ||
      productCommissionValue > 100
    ) {
      nextErrors.productCommission = 'La comisión de productos debe estar entre 0 y 100.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    onSubmit({
      name: trimmedName,
      role: role.trim() || 'Profesional',
      phone: phone.trim() || null,
      commission_pct: round2(commissionValue),
      product_commission_pct: round2(productCommissionValue),
      color_hex: color.toUpperCase(),
      is_active: isActive,
      can_book_appointments: canBook,
    })
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      <div className="space-y-1.5">
        <label htmlFor="staff-name" className="text-sm font-medium">
          Nombre
        </label>
        <Input
          id="staff-name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder="Juan Pérez"
          autoComplete="off"
          aria-invalid={Boolean(errors.name)}
        />
        <FieldError>{errors.name ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="staff-role" className="text-sm font-medium">
          Rol
        </label>
        <Input
          id="staff-role"
          value={role}
          onChange={(event) => setRole(event.target.value)}
          placeholder="Barbero"
        />
      </div>

      <div className="space-y-1.5">
        <label htmlFor="staff-phone" className="text-sm font-medium">
          Teléfono <span className="font-normal text-muted">(opcional)</span>
        </label>
        <Input
          id="staff-phone"
          type="tel"
          inputMode="tel"
          value={phone}
          onChange={(event) => setPhone(event.target.value)}
          placeholder="11 5555 5555"
          autoComplete="off"
          aria-invalid={Boolean(errors.phone)}
        />
        <FieldError>{errors.phone ?? null}</FieldError>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="staff-commission" className="text-sm font-medium">
            Comisión servicios (%)
          </label>
          <Input
            id="staff-commission"
            inputMode="decimal"
            value={commission}
            onChange={(event) => setCommission(event.target.value)}
            placeholder="50"
            className="numeric"
            aria-invalid={Boolean(errors.commission)}
          />
          <FieldError>{errors.commission ?? null}</FieldError>
        </div>
        <div className="space-y-1.5">
          <label htmlFor="staff-product-commission" className="text-sm font-medium">
            Comisión productos (%)
          </label>
          <Input
            id="staff-product-commission"
            inputMode="decimal"
            value={productCommission}
            onChange={(event) => setProductCommission(event.target.value)}
            placeholder="10"
            className="numeric"
            aria-invalid={Boolean(errors.productCommission)}
          />
          <FieldError>{errors.productCommission ?? null}</FieldError>
        </div>
      </div>

      <div className="space-y-1.5">
        <span className="text-sm font-medium">Color en la agenda</span>
        <div className="flex items-center gap-3">
          <input
            id="staff-color"
            type="color"
            value={color}
            onChange={(event) => setColor(event.target.value)}
            aria-label="Color en la agenda"
            className="h-11 w-14 cursor-pointer rounded-lg border border-base bg-surface p-1"
          />
          <span className="numeric text-xs text-muted">{color.toUpperCase()}</span>
        </div>
      </div>

      <Checkbox
        label="Activo (puede recibir turnos)"
        checked={isActive}
        onChange={(event) => setIsActive(event.target.checked)}
      />

      <Checkbox
        label="Puede agendar turnos (crea clientes y turnos para sí mismo)"
        checked={canBook}
        onChange={(event) => setCanBook(event.target.checked)}
      />

      <FieldError>{error}</FieldError>

      <div className="space-y-2 pt-1">
        <Button type="submit" loading={pending}>
          {member ? 'Guardar cambios' : 'Agregar al equipo'}
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

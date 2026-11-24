import { useEffect, useState, type FormEvent } from 'react'
import { dateKeyLongLabel, zonedTime } from '../lib/datetime'
import { createCashIncome, movementDateForDay } from '../lib/cash'
import { formatMoney, formatPercent } from '../lib/format'
import type { AppointmentView } from '../types/appointment'
import type { CatalogItem } from '../types/catalog'
import type { PaymentMethod } from '../types/cash'
import type { StaffMember } from '../types/staff'
import { Button, FieldError, Input, Select } from './ui/controls'
import { parseAmount, PaymentMethodSelect, round2 } from './CashFormFields'

type FieldErrors = Partial<
  Record<'description' | 'gross' | 'discount' | 'supply' | 'staff', string>
>

export function CashIncomeForm({
  shopId,
  timezone,
  dateKey,
  appointments,
  staff,
  items,
  onSaved,
  onCancel,
}: {
  shopId: string
  timezone: string
  dateKey: string
  appointments: AppointmentView[]
  staff: StaffMember[]
  items: CatalogItem[]
  onSaved: (message?: string) => void
  onCancel: () => void
}) {
  const defaultStaffId = staff.find((member) => member.is_active)?.id ?? staff[0]?.id ?? ''

  const [appointmentId, setAppointmentId] = useState('')
  const [staffId, setStaffId] = useState(defaultStaffId)
  const [itemId, setItemId] = useState('')
  const [description, setDescription] = useState('')
  const [gross, setGross] = useState('')
  const [discount, setDiscount] = useState('0')
  const [supply, setSupply] = useState('0')
  const [paymentMethod, setPaymentMethod] = useState<PaymentMethod>('cash')

  const [errors, setErrors] = useState<FieldErrors>({})
  const [pending, setPending] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  useEffect(() => {
    if (staffId) return
    const fallback = staff.find((member) => member.is_active)?.id ?? staff[0]?.id
    if (fallback) setStaffId(fallback)
  }, [staff, staffId])

  const selectedItem = items.find((item) => item.id === itemId) ?? null
  const selectedStaff = staff.find((member) => member.id === staffId) ?? null
  const commissionPct = selectedStaff
    ? selectedItem?.type === 'product'
      ? selectedStaff.product_commission_pct
      : selectedStaff.commission_pct
    : 0

  const grossValue = parseAmount(gross)
  const discountValue = discount.trim() === '' ? 0 : parseAmount(discount)
  const supplyValue = supply.trim() === '' ? 0 : parseAmount(supply)
  const safeGross = Number.isFinite(grossValue) ? Math.max(0, grossValue) : 0
  const safeDiscount = Number.isFinite(discountValue) ? Math.max(0, discountValue) : 0
  const safeSupply = Number.isFinite(supplyValue) ? Math.max(0, supplyValue) : 0
  const netBase = Math.max(0, round2(safeGross - safeDiscount - safeSupply))
  const commission = round2((netBase * commissionPct) / 100)
  const shopNet = round2(netBase - commission)

  function chooseAppointment(value: string) {
    setAppointmentId(value)
    const appointment = appointments.find((row) => row.id === value)
    if (!appointment) return

    const service = items.find((item) => item.id === appointment.service_id) ?? null
    setStaffId(appointment.staff_id)
    setItemId(appointment.service_id ?? '')
    setDescription(
      service
        ? `${service.name} · ${appointment.client_name_snapshot}`
        : `Turno · ${appointment.client_name_snapshot}`,
    )
    setGross(service ? String(service.price) : '')
    setSupply(service ? String(service.default_supply_cost) : '0')
    setDiscount('0')
    setErrors({})
    setSubmitError(null)
  }

  function chooseItem(value: string) {
    setItemId(value)
    const item = items.find((row) => row.id === value)
    if (!item) return

    setDescription((current) => (current.trim() ? current : item.name))
    setGross(String(item.price))
    setSupply(String(item.default_supply_cost))
    setErrors((current) => ({ ...current, gross: undefined, supply: undefined }))
    setSubmitError(null)
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    const trimmedDescription = description.trim()

    if (trimmedDescription.length < 2 || trimmedDescription.length > 200) {
      nextErrors.description = 'La descripción debe tener entre 2 y 200 caracteres.'
    }
    if (gross.trim() === '' || !Number.isFinite(grossValue) || grossValue < 0) {
      nextErrors.gross = 'Ingresá un importe válido (0 o más).'
    }
    if (!Number.isFinite(discountValue) || discountValue < 0) {
      nextErrors.discount = 'El descuento debe ser 0 o más.'
    }
    if (!Number.isFinite(supplyValue) || supplyValue < 0) {
      nextErrors.supply = 'Los insumos deben ser 0 o más.'
    }
    if (
      Number.isFinite(grossValue) &&
      Number.isFinite(discountValue) &&
      Number.isFinite(supplyValue) &&
      discountValue + supplyValue > grossValue
    ) {
      nextErrors.gross = 'El descuento más los insumos no pueden superar el bruto.'
    }
    if (!staffId) {
      nextErrors.staff = 'Elegí el profesional que realizó el trabajo.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    setPending(true)
    setSubmitError(null)
    try {
      const result = await createCashIncome(shopId, {
        appointment_id: appointmentId || null,
        staff_id: staffId,
        item_id: itemId || null,
        description: trimmedDescription,
        payment_method: paymentMethod,
        gross_amount: round2(grossValue),
        discount_amount: round2(discountValue),
        supply_deduction: round2(supplyValue),
        movement_date: movementDateForDay(dateKey, timezone),
      })
      onSaved(
        result.queued
          ? 'Cobro guardado sin conexión. Se sincronizará al reconectar.'
          : undefined,
      )
    } catch (error) {
      setSubmitError(
        error instanceof Error ? error.message : 'No pudimos registrar el cobro.',
      )
    } finally {
      setPending(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      <div className="space-y-1.5">
        <label htmlFor="cash-appointment" className="text-sm font-medium">
          Turno <span className="font-normal text-muted">(opcional)</span>
        </label>
        <Select
          id="cash-appointment"
          value={appointmentId}
          onChange={(event) => chooseAppointment(event.target.value)}
        >
          <option value="">Sin turno · venta directa</option>
          {appointments.map((appointment) => (
            <option key={appointment.id} value={appointment.id}>
              {zonedTime(appointment.starts_at, timezone)} ·{' '}
              {appointment.client_name_snapshot}
              {appointment.service ? ` · ${appointment.service.name}` : ''}
            </option>
          ))}
        </Select>
        <p className="text-xs text-muted">
          Solo se listan turnos del día sin un cobro registrado.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="cash-staff" className="text-sm font-medium">
            Profesional
          </label>
          <Select
            id="cash-staff"
            value={staffId}
            onChange={(event) => setStaffId(event.target.value)}
            aria-invalid={Boolean(errors.staff)}
          >
            {staff.length === 0 && <option value="">Sin profesionales</option>}
            {staff.map((member) => (
              <option key={member.id} value={member.id}>
                {member.name}
                {member.is_active ? '' : ' (inactivo)'}
              </option>
            ))}
          </Select>
          <FieldError>{errors.staff ?? null}</FieldError>
        </div>

        <div className="space-y-1.5">
          <label htmlFor="cash-item" className="text-sm font-medium">
            Servicio / producto
          </label>
          <Select id="cash-item" value={itemId} onChange={(event) => chooseItem(event.target.value)}>
            <option value="">Sin ítem</option>
            {items.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} · {item.type === 'service' ? 'servicio' : 'producto'}
                {item.is_active ? '' : ' (inactivo)'}
              </option>
            ))}
          </Select>
        </div>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="cash-description" className="text-sm font-medium">
          Descripción
        </label>
        <Input
          id="cash-description"
          value={description}
          onChange={(event) => setDescription(event.target.value)}
          maxLength={200}
          placeholder="Corte clásico · Juan Pérez"
          aria-invalid={Boolean(errors.description)}
        />
        <FieldError>{errors.description ?? null}</FieldError>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="cash-gross" className="text-sm font-medium">
            Importe bruto (ARS)
          </label>
          <Input
            id="cash-gross"
            inputMode="decimal"
            value={gross}
            onChange={(event) => setGross(event.target.value)}
            placeholder="16500"
            className="numeric"
            aria-invalid={Boolean(errors.gross)}
          />
          <FieldError>{errors.gross ?? null}</FieldError>
        </div>

        <div className="space-y-1.5">
          <label htmlFor="cash-discount" className="text-sm font-medium">
            Descuento al cliente
          </label>
          <Input
            id="cash-discount"
            inputMode="decimal"
            value={discount}
            onChange={(event) => setDiscount(event.target.value)}
            placeholder="0"
            className="numeric"
            aria-invalid={Boolean(errors.discount)}
          />
          <FieldError>{errors.discount ?? null}</FieldError>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="cash-supply" className="text-sm font-medium">
            Insumos
          </label>
          <Input
            id="cash-supply"
            inputMode="decimal"
            value={supply}
            onChange={(event) => setSupply(event.target.value)}
            placeholder="0"
            className="numeric"
            aria-invalid={Boolean(errors.supply)}
          />
          <FieldError>{errors.supply ?? null}</FieldError>
        </div>

        <div className="space-y-1.5">
          <label htmlFor="cash-payment" className="text-sm font-medium">
            Medio de pago
          </label>
          <PaymentMethodSelect
            id="cash-payment"
            value={paymentMethod}
            onChange={setPaymentMethod}
          />
        </div>
      </div>

      <div className="rounded-xl border border-base bg-surface-alt/60 p-3">
        <div className="flex items-baseline justify-between gap-3 text-sm">
          <span className="text-muted">Base comisionable</span>
          <span className="numeric font-semibold">{formatMoney(netBase)}</span>
        </div>
        <div className="mt-1 flex items-baseline justify-between gap-3 text-sm">
          <span className="text-muted">
            Comisión {selectedStaff ? `(${formatPercent(commissionPct)})` : ''}
          </span>
          <span className="numeric font-semibold text-pending">{formatMoney(commission)}</span>
        </div>
        <div className="mt-2 flex items-baseline justify-between gap-3 border-t border-base pt-2 text-sm">
          <span className="font-semibold">Neto del local</span>
          <span className="numeric font-bold text-income">{formatMoney(shopNet)}</span>
        </div>
        <p className="mt-2 text-[11px] text-muted">
          Cálculo estimado. Al guardar, la base recalcula según el profesional y el tipo de ítem.
        </p>
      </div>

      {staff.length === 0 && (
        <p className="rounded-lg border border-base bg-expense-soft px-3 py-2 text-xs font-medium text-expense">
          Agregá un profesional en Equipo para poder registrar cobros.
        </p>
      )}

      <p className="text-xs text-muted">
        Se registra en la caja del {dateKeyLongLabel(dateKey)}.
      </p>

      <FieldError>{submitError}</FieldError>

      <div className="space-y-2 pt-1">
        <Button type="submit" loading={pending} disabled={staff.length === 0}>
          Registrar cobro
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

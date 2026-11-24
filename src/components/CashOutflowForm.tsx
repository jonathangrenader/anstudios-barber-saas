import { useEffect, useState, type FormEvent } from 'react'
import { dateKeyLongLabel } from '../lib/datetime'
import { createCashOutflow, movementDateForDay } from '../lib/cash'
import type { PaymentMethod } from '../types/cash'
import type { StaffMember } from '../types/staff'
import { Button, FieldError, Input, Select } from './ui/controls'
import { parseAmount, PaymentMethodSelect, round2 } from './CashFormFields'

type FieldErrors = Partial<Record<'description' | 'amount' | 'staff', string>>

export function CashOutflowForm({
  shopId,
  timezone,
  dateKey,
  kind,
  staff,
  onSaved,
  onCancel,
}: {
  shopId: string
  timezone: string
  dateKey: string
  kind: 'expense' | 'staff_advance'
  staff: StaffMember[]
  onSaved: (message?: string) => void
  onCancel: () => void
}) {
  const isAdvance = kind === 'staff_advance'
  const activeStaff = staff.filter((member) => member.is_active)
  const [description, setDescription] = useState(
    kind === 'staff_advance' ? 'Adelanto' : '',
  )
  const [staffId, setStaffId] = useState(activeStaff[0]?.id ?? '')
  const [amount, setAmount] = useState('')
  const [paymentMethod, setPaymentMethod] = useState<PaymentMethod>('cash')

  const [errors, setErrors] = useState<FieldErrors>({})
  const [pending, setPending] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  useEffect(() => {
    if (staffId || !isAdvance) return
    const fallback = staff.find((member) => member.is_active)?.id
    if (fallback) setStaffId(fallback)
  }, [staff, isAdvance, staffId])

  const amountValue = parseAmount(amount)

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    const trimmedDescription = description.trim()

    if (trimmedDescription.length < 2 || trimmedDescription.length > 200) {
      nextErrors.description = 'La descripción debe tener entre 2 y 200 caracteres.'
    }
    if (!Number.isFinite(amountValue) || amountValue <= 0) {
      nextErrors.amount = 'Ingresá un importe mayor a cero.'
    }
    if (isAdvance && !staffId) {
      nextErrors.staff = 'Elegí a qué profesional se le entrega el adelanto.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    setPending(true)
    setSubmitError(null)
    try {
      const result = await createCashOutflow(shopId, {
        movement_type: kind,
        staff_id: isAdvance ? staffId : null,
        description: trimmedDescription,
        payment_method: paymentMethod,
        gross_amount: round2(amountValue),
        movement_date: movementDateForDay(dateKey, timezone),
      })
      onSaved(
        result.queued
          ? 'Movimiento guardado sin conexión. Se sincronizará al reconectar.'
          : undefined,
      )
    } catch (error) {
      setSubmitError(
        error instanceof Error ? error.message : 'No pudimos registrar el movimiento.',
      )
    } finally {
      setPending(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      {isAdvance && (
        <div className="space-y-1.5">
          <label htmlFor="outflow-staff" className="text-sm font-medium">
            Profesional
          </label>
          <Select
            id="outflow-staff"
            value={staffId}
            onChange={(event) => setStaffId(event.target.value)}
            aria-invalid={Boolean(errors.staff)}
          >
            {activeStaff.length === 0 && <option value="">Sin profesionales activos</option>}
            {activeStaff.map((member) => (
              <option key={member.id} value={member.id}>
                {member.name}
              </option>
            ))}
          </Select>
          <FieldError>{errors.staff ?? null}</FieldError>
        </div>
      )}

      <div className="space-y-1.5">
        <label htmlFor="outflow-description" className="text-sm font-medium">
          Descripción
        </label>
        <Input
          id="outflow-description"
          value={description}
          onChange={(event) => setDescription(event.target.value)}
          maxLength={200}
          placeholder={isAdvance ? 'Adelanto de sueldo' : 'Compra de insumos'}
          aria-invalid={Boolean(errors.description)}
        />
        <FieldError>{errors.description ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="outflow-amount" className="text-sm font-medium">
          Importe (ARS)
        </label>
        <Input
          id="outflow-amount"
          inputMode="decimal"
          value={amount}
          onChange={(event) => setAmount(event.target.value)}
          placeholder="0"
          className="numeric"
          aria-invalid={Boolean(errors.amount)}
        />
        <FieldError>{errors.amount ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="outflow-payment" className="text-sm font-medium">
          Medio de pago
        </label>
        <PaymentMethodSelect
          id="outflow-payment"
          value={paymentMethod}
          onChange={setPaymentMethod}
        />
      </div>

      <p className="rounded-lg border border-base bg-surface-alt/60 px-3 py-2 text-xs text-muted">
        {isAdvance
          ? 'El adelanto sale de caja y se descuenta en la próxima liquidación del profesional.'
          : 'El gasto no lleva comisión ni entra en las liquidaciones.'}
      </p>

      <p className="text-xs text-muted">
        Se registra en la caja del {dateKeyLongLabel(dateKey)}.
      </p>

      <FieldError>{submitError}</FieldError>

      <div className="space-y-2 pt-1">
        <Button
          type="submit"
          loading={pending}
          disabled={isAdvance && activeStaff.length === 0}
        >
          {isAdvance ? 'Registrar adelanto' : 'Guardar gasto'}
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

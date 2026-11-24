import type { PaymentMethod } from '../types/cash'
import { Select } from './ui/controls'

export const PAYMENT_METHODS: { value: PaymentMethod; label: string }[] = [
  { value: 'cash', label: 'Efectivo' },
  { value: 'transfer', label: 'Transferencia' },
  { value: 'card', label: 'Tarjeta' },
  { value: 'qr', label: 'QR' },
]

export function paymentMethodLabel(method: PaymentMethod): string {
  return PAYMENT_METHODS.find((option) => option.value === method)?.label ?? method
}

export function parseAmount(raw: string): number {
  return Number(raw.trim().replace(',', '.'))
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100
}

export function PaymentMethodSelect({
  id,
  value,
  onChange,
}: {
  id: string
  value: PaymentMethod
  onChange: (value: PaymentMethod) => void
}) {
  return (
    <Select
      id={id}
      value={value}
      onChange={(event) => onChange(event.target.value as PaymentMethod)}
    >
      {PAYMENT_METHODS.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </Select>
  )
}

import { useState, type FormEvent } from 'react'
import { normalizePhone } from '../lib/clients'
import type { Client, ClientInput } from '../types/client'
import { Button, FieldError, Input, Textarea } from './ui/controls'

type FieldErrors = Partial<Record<'name' | 'phone' | 'notes', string>>

export function ClientForm({
  client,
  pending,
  error,
  onSubmit,
  onCancel,
}: {
  client: Client | null
  pending: boolean
  error: string | null
  onSubmit: (input: ClientInput) => void
  onCancel: () => void
}) {
  const [name, setName] = useState(client?.full_name ?? '')
  const [phone, setPhone] = useState(client?.phone ?? '')
  const [notes, setNotes] = useState(client?.technical_notes ?? '')
  const [errors, setErrors] = useState<FieldErrors>({})

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    const trimmedName = name.trim()
    const digits = normalizePhone(phone)

    if (trimmedName.length < 2 || trimmedName.length > 80) {
      nextErrors.name = 'El nombre debe tener entre 2 y 80 caracteres.'
    }
    if (digits.length < 8 || digits.length > 20) {
      nextErrors.phone = 'Ingresá un teléfono de 8 a 20 dígitos.'
    }
    if (notes.length > 2000) {
      nextErrors.notes = 'La ficha técnica no puede superar los 2000 caracteres.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    onSubmit({
      full_name: trimmedName,
      phone: digits,
      technical_notes: notes.trim() || null,
    })
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      <div className="space-y-1.5">
        <label htmlFor="client-name" className="text-sm font-medium">
          Nombre completo
        </label>
        <Input
          id="client-name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder="Martina López"
          autoComplete="off"
          aria-invalid={Boolean(errors.name)}
        />
        <FieldError>{errors.name ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="client-phone" className="text-sm font-medium">
          Teléfono
        </label>
        <Input
          id="client-phone"
          type="tel"
          inputMode="tel"
          value={phone}
          onChange={(event) => setPhone(event.target.value)}
          placeholder="11 5555 5555"
          autoComplete="off"
          aria-invalid={Boolean(errors.phone)}
        />
        <p className="text-xs text-muted">
          Es la clave del cliente en el local: se guarda solo con números.
        </p>
        <FieldError>{errors.phone ?? null}</FieldError>
      </div>

      <div className="space-y-1.5">
        <label htmlFor="client-notes" className="text-sm font-medium">
          Ficha técnica <span className="font-normal text-muted">(opcional)</span>
        </label>
        <Textarea
          id="client-notes"
          value={notes}
          onChange={(event) => setNotes(event.target.value)}
          maxLength={2000}
          placeholder="Fórmulas, alergias, preferencias de corte…"
          aria-invalid={Boolean(errors.notes)}
        />
        <div className="flex items-center justify-between gap-2">
          <FieldError>{errors.notes ?? null}</FieldError>
          <span className="numeric ml-auto text-[11px] text-muted">{notes.length}/2000</span>
        </div>
      </div>

      <FieldError>{error}</FieldError>

      <div className="space-y-2 pt-1">
        <Button type="submit" loading={pending}>
          {client ? 'Guardar cambios' : 'Agregar cliente'}
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

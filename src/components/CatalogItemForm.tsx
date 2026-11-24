import { useState, type FormEvent } from 'react'
import type { CatalogItem, CatalogItemInput, CatalogItemType } from '../types/catalog'
import { Button, Checkbox, FieldError, Input } from './ui/controls'

type FieldErrors = Partial<Record<'name' | 'price' | 'duration' | 'supply', string>>

function parseNumber(raw: string): number {
  return Number(raw.trim().replace(',', '.'))
}

function round2(value: number): number {
  return Math.round(value * 100) / 100
}

export function CatalogItemForm({
  item,
  pending,
  error,
  onSubmit,
  onCancel,
}: {
  item: CatalogItem | null
  pending: boolean
  error: string | null
  onSubmit: (input: CatalogItemInput) => void
  onCancel: () => void
}) {
  const [type, setType] = useState<CatalogItemType>(item?.type ?? 'service')
  const [name, setName] = useState(item?.name ?? '')
  const [price, setPrice] = useState(item ? String(item.price) : '')
  const [duration, setDuration] = useState(item ? String(item.duration_min) : '30')
  const [supply, setSupply] = useState(item ? String(item.default_supply_cost) : '0')
  const [isPublic, setIsPublic] = useState(item?.is_public ?? true)
  const [errors, setErrors] = useState<FieldErrors>({})

  function changeType(next: CatalogItemType) {
    setType(next)
    if (next === 'product') {
      setDuration('0')
    } else if (parseNumber(duration) <= 0) {
      setDuration('30')
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    const nextErrors: FieldErrors = {}
    const trimmedName = name.trim()
    const priceValue = parseNumber(price)
    const supplyValue = supply.trim() === '' ? 0 : parseNumber(supply)
    const durationValue = type === 'product' ? 0 : Math.round(parseNumber(duration))

    if (trimmedName.length < 2 || trimmedName.length > 120) {
      nextErrors.name = 'El nombre debe tener entre 2 y 120 caracteres.'
    }
    if (!Number.isFinite(priceValue) || priceValue < 0) {
      nextErrors.price = 'Ingresá un precio válido (0 o más).'
    }
    if (!Number.isFinite(supplyValue) || supplyValue < 0) {
      nextErrors.supply = 'El costo de insumos debe ser 0 o más.'
    }
    if (type === 'service' && (!Number.isFinite(durationValue) || durationValue < 5 || durationValue > 480)) {
      nextErrors.duration = 'La duración debe estar entre 5 y 480 minutos.'
    }

    setErrors(nextErrors)
    if (Object.keys(nextErrors).length > 0) return

    onSubmit({
      type,
      name: trimmedName,
      duration_min: durationValue,
      price: round2(priceValue),
      default_supply_cost: round2(supplyValue),
      is_public: type === 'service' ? isPublic : false,
      is_active: item?.is_active ?? true,
    })
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4" noValidate>
      <div className="grid grid-cols-2 gap-1 rounded-lg border border-base bg-surface-alt p-1">
        {(['service', 'product'] as const).map((option) => (
          <button
            key={option}
            type="button"
            onClick={() => changeType(option)}
            aria-pressed={type === option}
            className={`min-h-[44px] rounded-md text-sm font-semibold transition-colors ${
              type === option ? 'border border-strong bg-surface text-ink' : 'text-muted'
            }`}
          >
            {option === 'service' ? 'Servicio' : 'Producto'}
          </button>
        ))}
      </div>

      <div className="space-y-1.5">
        <label htmlFor="catalog-name" className="text-sm font-medium">
          Nombre
        </label>
        <Input
          id="catalog-name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder={type === 'service' ? 'Corte clásico' : 'Cera matte'}
          aria-invalid={Boolean(errors.name)}
        />
        <FieldError>{errors.name ?? null}</FieldError>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-1.5">
          <label htmlFor="catalog-price" className="text-sm font-medium">
            Precio (ARS)
          </label>
          <Input
            id="catalog-price"
            inputMode="decimal"
            value={price}
            onChange={(event) => setPrice(event.target.value)}
            placeholder="16500"
            className="numeric"
            aria-invalid={Boolean(errors.price)}
          />
        </div>

        {type === 'service' ? (
          <div className="space-y-1.5">
            <label htmlFor="catalog-duration" className="text-sm font-medium">
              Duración (min)
            </label>
            <Input
              id="catalog-duration"
              inputMode="numeric"
              value={duration}
              onChange={(event) => setDuration(event.target.value)}
              placeholder="30"
              className="numeric"
              aria-invalid={Boolean(errors.duration)}
            />
          </div>
        ) : (
          <div className="space-y-1.5">
            <span className="text-sm font-medium">Duración</span>
            <p className="flex min-h-[44px] items-center text-xs text-muted">
              Los productos no se agendan.
            </p>
          </div>
        )}
      </div>
      <FieldError>{errors.price ?? null}</FieldError>
      <FieldError>{errors.duration ?? null}</FieldError>

      <div className="space-y-1.5">
        <label htmlFor="catalog-supply" className="text-sm font-medium">
          Costo de insumos sugerido (ARS)
        </label>
        <Input
          id="catalog-supply"
          inputMode="decimal"
          value={supply}
          onChange={(event) => setSupply(event.target.value)}
          placeholder="0"
          className="numeric"
          aria-invalid={Boolean(errors.supply)}
        />
        <p className="text-xs text-muted">Se descuenta antes de calcular la comisión al cobrar.</p>
        <FieldError>{errors.supply ?? null}</FieldError>
      </div>

      {type === 'service' && (
        <Checkbox
          label="Mostrar en el link público de reservas"
          checked={isPublic}
          onChange={(event) => setIsPublic(event.target.checked)}
        />
      )}

      <FieldError>{error}</FieldError>

      <div className="space-y-2 pt-1">
        <Button type="submit" loading={pending}>
          {item ? 'Guardar cambios' : 'Agregar al catálogo'}
        </Button>
        <Button type="button" variant="secondary" onClick={onCancel} disabled={pending}>
          Cancelar
        </Button>
      </div>
    </form>
  )
}

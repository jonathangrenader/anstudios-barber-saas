import { useState } from 'react'
import { Loader2, Pencil, Plus } from 'lucide-react'
import { useCatalog } from '../hooks/useCatalog'
import { formatMoney } from '../lib/format'
import type { CatalogItem, CatalogItemInput } from '../types/catalog'
import { CatalogItemForm } from './CatalogItemForm'
import { Modal } from './ui/Modal'
import { Button } from './ui/controls'

function CatalogItemCard({
  item,
  onEdit,
  onToggle,
  onDelete,
}: {
  item: CatalogItem
  onEdit: () => void
  onToggle: () => void
  onDelete: () => void
}) {
  const [confirming, setConfirming] = useState(false)

  return (
    <li className="rounded-xl border border-base bg-surface p-3">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <p className="truncate text-sm font-semibold">{item.name}</p>
            {!item.is_active && (
              <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Inactivo
              </span>
            )}
          </div>
          <p className="numeric mt-1 text-xs text-muted">
            {item.type === 'service' ? `${item.duration_min} min · ` : ''}
            {formatMoney(item.price)}
          </p>
          {item.default_supply_cost > 0 && (
            <p className="numeric mt-0.5 text-xs text-muted">
              Insumos: {formatMoney(item.default_supply_cost)}
            </p>
          )}
        </div>
        <button
          type="button"
          onClick={onEdit}
          aria-label={`Editar ${item.name}`}
          className="flex size-11 shrink-0 items-center justify-center rounded-lg border border-base text-muted hover:bg-surface-alt"
        >
          <Pencil size={16} aria-hidden="true" />
        </button>
      </div>

      <div className="mt-2 flex items-center justify-between gap-2 border-t border-base pt-1">
        <button
          type="button"
          onClick={onToggle}
          className="min-h-[44px] px-1 text-xs font-medium text-muted hover:text-ink"
        >
          {item.is_active ? 'Desactivar' : 'Activar'}
        </button>

        {confirming ? (
          <span className="flex items-center gap-1">
            <span className="text-xs text-muted">¿Eliminar?</span>
            <button
              type="button"
              onClick={() => {
                setConfirming(false)
                onDelete()
              }}
              className="min-h-[44px] px-2 text-xs font-semibold text-expense"
            >
              Sí
            </button>
            <button
              type="button"
              onClick={() => setConfirming(false)}
              className="min-h-[44px] px-2 text-xs text-muted"
            >
              No
            </button>
          </span>
        ) : (
          <button
            type="button"
            onClick={() => setConfirming(true)}
            className="min-h-[44px] px-1 text-xs font-medium text-muted hover:text-expense"
          >
            Eliminar
          </button>
        )}
      </div>
    </li>
  )
}

export function CatalogScreen({ shopId }: { shopId: string }) {
  const { items, loading, error, reload, save, remove, toggleActive } = useCatalog(shopId)
  const [formOpen, setFormOpen] = useState(false)
  const [editing, setEditing] = useState<CatalogItem | null>(null)
  const [pending, setPending] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  const services = items.filter((item) => item.type === 'service')
  const products = items.filter((item) => item.type === 'product')
  const groups = [
    { title: 'Servicios', items: services },
    { title: 'Productos', items: products },
  ]

  function openCreate() {
    setEditing(null)
    setFormError(null)
    setFormOpen(true)
  }

  function openEdit(item: CatalogItem) {
    setEditing(item)
    setFormError(null)
    setFormOpen(true)
  }

  async function handleSubmit(input: CatalogItemInput) {
    setPending(true)
    setFormError(null)
    try {
      await save(input, editing?.id)
      setFormOpen(false)
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'No pudimos guardar el ítem.')
    } finally {
      setPending(false)
    }
  }

  async function run(action: () => Promise<void>) {
    setActionError(null)
    try {
      await action()
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'No pudimos completar la acción.')
    }
  }

  return (
    <section aria-labelledby="catalog-heading">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="catalog-heading" className="text-base font-bold">
            Catálogo
          </h2>
          <p className="mt-0.5 text-xs text-muted">Servicios y productos que cobrás.</p>
        </div>
        <button
          type="button"
          onClick={openCreate}
          className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-3 text-sm font-semibold text-white shadow-tactile"
        >
          <Plus size={16} aria-hidden="true" />
          Nuevo
        </button>
      </div>

      {actionError && (
        <p role="alert" className="mt-3 rounded-lg border border-expense/30 bg-expense-soft px-3 py-2 text-xs font-medium text-expense">
          {actionError}
        </p>
      )}

      {loading && (
        <p className="mt-6 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando catálogo…
        </p>
      )}

      {!loading && error && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm text-ink">{error}</p>
          <div className="mt-3">
            <Button type="button" variant="secondary" onClick={() => void reload()}>
              Reintentar
            </Button>
          </div>
        </div>
      )}

      {!loading && !error && items.length === 0 && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">Todavía no cargaste nada.</p>
          <p className="mt-1 text-xs text-muted">
            Empezá por un servicio para que aparezca en el link de reservas.
          </p>
          <div className="mt-4">
            <Button type="button" onClick={openCreate}>
              Agregar el primero
            </Button>
          </div>
        </div>
      )}

      {groups.map((group) =>
        group.items.length > 0 ? (
          <div key={group.title} className="mt-5">
            <h3 className="mb-2 text-xs font-semibold uppercase tracking-[0.12em] text-muted">
              {group.title} · {group.items.length}
            </h3>
            <ul className="space-y-2">
              {group.items.map((item) => (
                <CatalogItemCard
                  key={item.id}
                  item={item}
                  onEdit={() => openEdit(item)}
                  onToggle={() => void run(() => toggleActive(item))}
                  onDelete={() => void run(() => remove(item.id))}
                />
              ))}
            </ul>
          </div>
        ) : null,
      )}

      <Modal
        open={formOpen}
        title={editing ? 'Editar ítem' : 'Nuevo ítem'}
        onClose={() => {
          if (!pending) setFormOpen(false)
        }}
      >
        <CatalogItemForm
          item={editing}
          pending={pending}
          error={formError}
          onSubmit={(input) => void handleSubmit(input)}
          onCancel={() => setFormOpen(false)}
        />
      </Modal>
    </section>
  )
}

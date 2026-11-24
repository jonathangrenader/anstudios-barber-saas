import { useState } from 'react'
import { ArrowLeft, ChevronRight, Loader2, Plus, Search } from 'lucide-react'
import { useClients } from '../hooks/useClients'
import { normalizePhone } from '../lib/clients'
import type { Client, ClientInput } from '../types/client'
import { ClientDetail } from './ClientDetail'
import { ClientForm } from './ClientForm'
import { Modal } from './ui/Modal'
import { Button, Input } from './ui/controls'

function fold(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
}

export function ClientsScreen({ shopId, timezone, onBack }: { shopId: string; timezone: string; onBack: () => void }) {
  const { clients, loading, error, reload, save } = useClients(shopId)
  const [query, setQuery] = useState('')
  const [modal, setModal] = useState<'detail' | 'form' | null>(null)
  const [detail, setDetail] = useState<Client | null>(null)
  const [editing, setEditing] = useState<Client | null>(null)
  const [pending, setPending] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const search = fold(query.trim())
  const digits = search.replace(/\D/g, '')
  const filtered = search
    ? clients.filter(
        (client) =>
          fold(client.full_name).includes(search) ||
          (digits.length > 0 && client.phone.includes(digits)) ||
          fold(client.technical_notes ?? '').includes(search),
      )
    : clients

  function openCreate() {
    setEditing(null)
    setFormError(null)
    setModal('form')
  }

  function openDetail(client: Client) {
    setDetail(client)
    setModal('detail')
  }

  function openEdit(client: Client) {
    setEditing(client)
    setFormError(null)
    setModal('form')
  }

  async function handleSubmit(input: ClientInput) {
    setPending(true)
    setFormError(null)
    try {
      const result = await save(input, editing?.id)
      setNotice(
        result.queued
          ? 'Cliente guardado sin conexión. Se sincronizará al reconectar.'
          : null,
      )

      if (editing && detail && detail.id === editing.id) {
        setDetail({
          ...editing,
          full_name: input.full_name,
          phone: normalizePhone(input.phone),
          technical_notes: input.technical_notes?.trim() || null,
        })
        setModal('detail')
      } else {
        setModal(null)
      }
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'No pudimos guardar el cliente.')
    } finally {
      setPending(false)
    }
  }

  return (
    <section aria-labelledby="clients-heading">
      <button
        type="button"
        onClick={onBack}
        className="mb-3 inline-flex min-h-[44px] items-center gap-1.5 text-xs font-semibold text-muted hover:text-ink"
      >
        <ArrowLeft size={15} aria-hidden="true" />
        Volver a agenda
      </button>

      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="clients-heading" className="text-base font-bold">
            Clientes
          </h2>
          <p className="mt-0.5 text-xs text-muted">Fichas técnicas e historial de visitas.</p>
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

      {notice && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending"
        >
          {notice}
        </p>
      )}

      <div className="relative mt-4">
        <Search
          size={16}
          aria-hidden="true"
          className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted"
        />
        <Input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Buscar por nombre, teléfono o nota…"
          aria-label="Buscar clientes"
          className="pl-9"
        />
      </div>

      {loading && (
        <p className="mt-6 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando clientes…
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

      {!loading && !error && clients.length === 0 && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">Todavía no hay clientes.</p>
          <p className="mt-1 text-xs text-muted">
            Se crean al agendar un turno o cargándolos acá con su ficha técnica.
          </p>
          <div className="mt-4">
            <Button type="button" onClick={openCreate}>
              Agregar el primero
            </Button>
          </div>
        </div>
      )}

      {!loading && !error && clients.length > 0 && filtered.length === 0 && (
        <p className="mt-5 text-sm text-muted">No encontramos clientes con esa búsqueda.</p>
      )}

      {filtered.length > 0 && (
        <ul className="mt-4 space-y-2">
          {filtered.map((client) => (
            <li key={client.id}>
              <button
                type="button"
                onClick={() => openDetail(client)}
                className="flex min-h-[64px] w-full items-center justify-between gap-3 rounded-xl border border-base bg-surface p-3 text-left hover:bg-surface-alt/60"
              >
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold">{client.full_name}</p>
                  <p className="numeric mt-0.5 text-xs text-muted">{client.phone}</p>
                  {client.technical_notes && (
                    <p className="mt-1 line-clamp-1 text-xs text-muted">
                      {client.technical_notes}
                    </p>
                  )}
                </div>
                <div className="flex shrink-0 items-center gap-2">
                  {client.sync_status && (
                    <span
                      className={`rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                        client.sync_status === 'failed'
                          ? 'bg-expense-soft text-expense'
                          : 'bg-pending-soft text-pending'
                      }`}
                    >
                      {client.sync_status === 'failed' ? 'Error' : 'Local'}
                    </span>
                  )}
                  {client.total_visits > 0 && (
                    <span className="numeric text-[11px] text-muted">
                      {client.total_visits} {client.total_visits === 1 ? 'visita' : 'visitas'}
                    </span>
                  )}
                  <ChevronRight size={16} className="text-muted" aria-hidden="true" />
                </div>
              </button>
            </li>
          ))}
        </ul>
      )}

      <Modal
        open={modal !== null}
        title={
          modal === 'form'
            ? editing
              ? 'Editar cliente'
              : 'Nuevo cliente'
            : (detail?.full_name ?? 'Cliente')
        }
        onClose={() => {
          if (pending) return
          if (modal === 'form' && editing && detail) setModal('detail')
          else setModal(null)
        }}
      >
        {modal === 'form' && (
          <ClientForm
            client={editing}
            pending={pending}
            error={formError}
            onSubmit={(input) => void handleSubmit(input)}
            onCancel={() => {
              if (editing && detail) setModal('detail')
              else setModal(null)
            }}
          />
        )}

        {modal === 'detail' && detail && (
          <ClientDetail
            key={detail.id}
            client={detail}
            timezone={timezone}
            visits={detail.total_visits}
            onEdit={() => openEdit(detail)}
            onSaved={(updated) => {
              setDetail(updated)
              void reload()
            }}
          />
        )}
      </Modal>

    </section>
  )
}

import { useEffect, useState } from 'react'
import { Pencil, Phone } from 'lucide-react'
import { updateClient, listClientVisits } from '../lib/clients'
import { zonedDateLabel, zonedTime } from '../lib/datetime'
import { STATUS_META } from '../lib/status'
import type { Client } from '../types/client'
import type { ClientVisit } from '../types/appointment'
import { Button, FieldError, Textarea } from './ui/controls'

export function ClientDetail({
  client,
  timezone,
  visits,
  onEdit,
  onSaved,
}: {
  client: Client
  timezone: string
  visits: number
  onEdit: () => void
  onSaved: (client: Client) => void
}) {
  const [notes, setNotes] = useState(client.technical_notes ?? '')
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)
  const [savedLocal, setSavedLocal] = useState(false)
  const [notesError, setNotesError] = useState<string | null>(null)
  const [history, setHistory] = useState<ClientVisit[]>([])
  const [historyLoading, setHistoryLoading] = useState(true)
  const [historyError, setHistoryError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setHistoryLoading(true)
    setHistoryError(null)

    listClientVisits(client.id)
      .then((rows) => {
        if (!cancelled) setHistory(rows)
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setHistoryError(
            err instanceof Error ? err.message : 'No pudimos cargar el historial.',
          )
        }
      })
      .finally(() => {
        if (!cancelled) setHistoryLoading(false)
      })

    return () => {
      cancelled = true
    }
  }, [client.id])

  async function saveNotes() {
    setSaving(true)
    setSaved(false)
    setNotesError(null)
    try {
      const result = await updateClient(client.id, client.shop_id, {
        technical_notes: notes,
      })
      onSaved({
        ...client,
        technical_notes: notes.trim() || null,
        ...(result.queued ? { sync_status: 'pending' as const } : {}),
      })
      setSaved(true)
      setSavedLocal(result.queued)
    } catch (err) {
      setNotesError(err instanceof Error ? err.message : 'No pudimos guardar la ficha.')
    } finally {
      setSaving(false)
    }
  }

  const notesDirty = notes.trim() !== (client.technical_notes ?? '').trim()

  return (
    <div className="space-y-5">
      <div className="flex items-start justify-between gap-3">
        <div className="space-y-1">
          <a
            href={`tel:${client.phone}`}
            className="numeric inline-flex min-h-[44px] items-center gap-2 text-sm text-ink underline-offset-4 hover:underline"
          >
            <Phone size={15} aria-hidden="true" />
            {client.phone}
          </a>
          <p className="text-xs text-muted">
            {visits > 0
              ? `${visits} ${visits === 1 ? 'visita completada' : 'visitas completadas'}`
              : 'Todavía sin visitas completadas'}
          </p>
        </div>
        <button
          type="button"
          onClick={onEdit}
          className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-base px-3 text-xs font-semibold text-muted hover:bg-surface-alt"
        >
          <Pencil size={14} aria-hidden="true" />
          Editar datos
        </button>
      </div>

      <section className="rounded-xl border border-base bg-surface-alt/60 p-3">
        <h3 className="text-xs font-semibold uppercase tracking-[0.12em] text-muted">
          Ficha técnica
        </h3>
        <Textarea
          value={notes}
          onChange={(event) => {
            setNotes(event.target.value)
            setSaved(false)
            setSavedLocal(false)
          }}
          maxLength={2000}
          placeholder="Fórmulas, alergias, preferencias…"
          className="mt-2 bg-surface"
          aria-label="Ficha técnica"
        />
        <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
          <span className="numeric text-[11px] text-muted">{notes.length}/2000</span>
          <div className="flex items-center gap-2">
            {saved && (
              <span
                className={`text-xs font-medium ${
                  savedLocal ? 'text-pending' : 'text-income'
                }`}
              >
                {savedLocal ? 'Guardado local' : 'Guardado'}
              </span>
            )}
            <div className="w-36">
              <Button
                type="button"
                variant="secondary"
                onClick={() => void saveNotes()}
                loading={saving}
                disabled={!notesDirty}
              >
                Guardar ficha
              </Button>
            </div>
          </div>
        </div>
        <FieldError>{notesError}</FieldError>
      </section>

      <section>
        <h3 className="text-xs font-semibold uppercase tracking-[0.12em] text-muted">
          Historial reciente
        </h3>

        {historyLoading && <p className="mt-3 text-sm text-muted">Cargando historial…</p>}
        <FieldError>{historyError}</FieldError>

        {!historyLoading && !historyError && history.length === 0 && (
          <p className="mt-2 text-sm text-muted">Sin turnos registrados todavía.</p>
        )}

        {history.length > 0 && (
          <ul className="mt-2 divide-y divide-base rounded-xl border border-base bg-surface">
            {history.map((visit) => {
              const meta = STATUS_META[visit.status]
              return (
                <li key={visit.id} className="px-3 py-3">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <p className="numeric text-xs font-semibold">
                        {zonedDateLabel(visit.starts_at, timezone)} ·{' '}
                        {zonedTime(visit.starts_at, timezone)}
                      </p>
                      <p className="mt-0.5 truncate text-sm">
                        {visit.service?.name ?? 'Sin servicio'}
                        {visit.staff ? ` · ${visit.staff.name}` : ''}
                      </p>
                      {visit.notes && (
                        <p className="mt-1 line-clamp-2 text-xs text-muted">{visit.notes}</p>
                      )}
                    </div>
                    <span
                      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${meta.className}`}
                    >
                      {meta.label}
                    </span>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </section>
    </div>
  )
}

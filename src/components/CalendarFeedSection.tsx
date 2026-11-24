import { useState } from 'react'
import { CalendarPlus, Check, Copy, Loader2, RefreshCw } from 'lucide-react'
import { calendarFeedUrl, getCalendarToken, rotateCalendarToken } from '../lib/calendarFeed'

async function copyText(value: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(value)
    return true
  } catch {
    return false
  }
}

/**
 * Link de suscripción ICS de la agenda de un profesional. El link se pide
 * recién al abrirlo para no guardar tokens en el caché offline.
 */
export function CalendarFeedSection({ staffId }: { staffId?: string }) {
  const [token, setToken] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [rotating, setRotating] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [copied, setCopied] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const url = token ? calendarFeedUrl(token) : ''

  async function load() {
    setLoading(true)
    setError(null)
    try {
      setToken(await getCalendarToken(staffId))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos obtener el link.')
    } finally {
      setLoading(false)
    }
  }

  async function copy() {
    if (!url) return
    setError(null)
    if (await copyText(url)) {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } else {
      window.prompt('Copiá el link del calendario', url)
    }
  }

  async function rotate() {
    setRotating(true)
    setError(null)
    try {
      setToken(await rotateCalendarToken(staffId))
      setConfirming(false)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos regenerar el link.')
    } finally {
      setRotating(false)
    }
  }

  return (
    <div className="mt-2 border-t border-base pt-2">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="flex items-center gap-1.5 text-xs font-semibold">
            <CalendarPlus size={13} className="shrink-0" aria-hidden="true" />
            Calendario del teléfono
          </p>
          <p className="mt-0.5 text-[11px] text-muted">
            Suscribite desde Google Calendar con “Desde URL”. Se actualiza cada varias horas y
            no incluye teléfonos ni notas.
          </p>
        </div>
      </div>

      {!token && (
        <button
          type="button"
          onClick={() => void load()}
          disabled={loading}
          className="mt-1.5 inline-flex min-h-[44px] items-center gap-1.5 text-xs font-medium text-muted underline-offset-4 hover:text-ink hover:underline disabled:opacity-60"
        >
          {loading ? (
            <Loader2 size={13} className="animate-spin" aria-hidden="true" />
          ) : (
            <CalendarPlus size={13} aria-hidden="true" />
          )}
          Obtener link de calendario
        </button>
      )}

      {token && (
        <div className="mt-1.5">
          <label htmlFor={`calendar-url-${staffId ?? 'me'}`} className="sr-only">
            Link del calendario
          </label>
          <input
            id={`calendar-url-${staffId ?? 'me'}`}
            readOnly
            value={url}
            onFocus={(event) => event.currentTarget.select()}
            className="w-full rounded-lg border border-base bg-surface-alt/60 px-2 py-2 text-[11px] text-muted"
          />
          <div className="mt-1.5 flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={() => void copy()}
              className="inline-flex min-h-[44px] items-center gap-1.5 rounded-lg border border-base bg-surface px-3 text-xs font-semibold hover:bg-surface-alt"
            >
              {copied ? (
                <Check size={14} className="text-income" aria-hidden="true" />
              ) : (
                <Copy size={14} aria-hidden="true" />
              )}
              {copied ? 'Copiado' : 'Copiar link'}
            </button>

            {confirming ? (
              <>
                <button
                  type="button"
                  onClick={() => void rotate()}
                  disabled={rotating}
                  className="inline-flex min-h-[44px] items-center gap-1.5 rounded-lg border border-base bg-expense-soft px-3 text-xs font-semibold text-expense disabled:opacity-60"
                >
                  {rotating && <Loader2 size={13} className="animate-spin" aria-hidden="true" />}
                  Sí, regenerar
                </button>
                <button
                  type="button"
                  onClick={() => setConfirming(false)}
                  disabled={rotating}
                  className="min-h-[44px] px-2 text-xs font-medium text-muted hover:text-ink"
                >
                  Cancelar
                </button>
              </>
            ) : (
              <button
                type="button"
                onClick={() => setConfirming(true)}
                className="inline-flex min-h-[44px] items-center gap-1.5 px-1 text-xs font-medium text-muted hover:text-ink"
              >
                <RefreshCw size={13} aria-hidden="true" />
                Regenerar
              </button>
            )}
          </div>
          {confirming && (
            <p className="mt-1 text-[11px] text-muted">
              El link anterior deja de funcionar. Volvé a suscribirte con el nuevo.
            </p>
          )}
        </div>
      )}

      {error && (
        <p role="alert" className="mt-1.5 text-xs font-medium text-expense">
          {error}
        </p>
      )}
    </div>
  )
}

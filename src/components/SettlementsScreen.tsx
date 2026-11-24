import { useEffect, useState } from 'react'
import {
  ArrowLeft,
  ChevronRight,
  HandCoins,
  Loader2,
} from 'lucide-react'
import { useSettlements } from '../hooks/useSettlements'
import { formatMoney } from '../lib/format'
import {
  closeStaffSettlement,
  previewStaffSettlement,
} from '../lib/settlements'
import type { PaymentMethod } from '../types/cash'
import type { Shop } from '../types/shop'
import type { StaffMember } from '../types/staff'
import type {
  SettlementCloseResult,
  SettlementPreview,
  StaffSettlementSummary,
} from '../types/settlement'
import { PaymentMethodSelect } from './CashFormFields'
import { Modal } from './ui/Modal'
import { Button, FieldError, Input } from './ui/controls'

function SummaryRow({
  label,
  value,
  negative = false,
  strong = false,
}: {
  label: string
  value: string
  negative?: boolean
  strong?: boolean
}) {
  return (
    <div
      className={`flex items-baseline justify-between gap-3 text-sm ${
        strong ? 'border-t border-base pt-2' : ''
      }`}
    >
      <span className={strong ? 'font-semibold' : 'text-muted'}>{label}</span>
      <span
        className={`numeric ${strong ? 'font-bold' : 'font-semibold'} ${
          negative ? 'text-expense' : 'text-ink'
        }`}
      >
        {value}
      </span>
    </div>
  )
}

export function SettlementsScreen({
  shop,
  staff,
  onBack,
  onSettled,
}: {
  shop: Shop
  staff: StaffMember[]
  onBack: () => void
  onSettled: () => void
}) {
  const { settlements, loading, error, reload } = useSettlements(shop.id)

  const [notice, setNotice] = useState<string | null>(null)
  const [selected, setSelected] = useState<StaffSettlementSummary | null>(null)
  const [preview, setPreview] = useState<SettlementPreview | null>(null)
  const [previewLoading, setPreviewLoading] = useState(false)
  const [previewError, setPreviewError] = useState<string | null>(null)
  const [previewAttempt, setPreviewAttempt] = useState(0)

  const [paymentMethod, setPaymentMethod] = useState<PaymentMethod>('cash')
  const [note, setNote] = useState('')
  const [confirming, setConfirming] = useState(false)
  const [closing, setClosing] = useState(false)
  const [closeError, setCloseError] = useState<string | null>(null)

  const pending = settlements.filter(
    (row) => row.pending_income_count > 0 || row.pending_advances > 0,
  )
  const ordered = [...pending].sort(
    (a, b) =>
      b.balance_due - a.balance_due || a.staff_name.localeCompare(b.staff_name, 'es'),
  )

  const totalCommission = ordered.reduce(
    (total, row) => total + row.pending_commission,
    0,
  )
  const totalAdvances = ordered.reduce(
    (total, row) => total + row.pending_advances,
    0,
  )
  const totalPayable = ordered.reduce(
    (total, row) => total + Math.max(0, row.balance_due),
    0,
  )

  useEffect(() => {
    if (!selected) return

    let active = true
    setPreview(null)
    setPreviewError(null)
    setPreviewLoading(true)

    previewStaffSettlement({
      shopId: shop.id,
      staffId: selected.staff_id,
      periodStart: shop.created_at,
      periodEnd: new Date().toISOString(),
    })
      .then((result) => {
        if (active) setPreview(result)
      })
      .catch((err: unknown) => {
        if (!active) return
        setPreviewError(
          err instanceof Error ? err.message : 'No pudimos calcular la liquidación.',
        )
      })
      .finally(() => {
        if (active) setPreviewLoading(false)
      })

    return () => {
      active = false
    }
  }, [selected, shop.id, shop.created_at, previewAttempt])

  function openSettlement(row: StaffSettlementSummary) {
    setNotice(null)
    setCloseError(null)
    setConfirming(false)
    setPaymentMethod('cash')
    setNote('')
    setPreviewAttempt(0)
    setSelected(row)
  }

  function closeModal() {
    if (closing) return
    setSelected(null)
    setPreview(null)
    setPreviewError(null)
    setConfirming(false)
    setCloseError(null)
  }

  async function handleClose() {
    if (!selected || !preview) return

    const staffName = selected.staff_name
    const trimmedNote = note.trim()
    setClosing(true)
    setCloseError(null)
    try {
      const result: SettlementCloseResult = await closeStaffSettlement({
        shopId: shop.id,
        staffId: selected.staff_id,
        periodStart: preview.period_start,
        periodEnd: preview.period_end,
        paymentMethod,
        notes: trimmedNote.length >= 2 ? trimmedNote : null,
      })

      if (!result.settled) {
        if (result.reason === 'saldo_a_favor_del_local') {
          setCloseError(
            'Los adelantos superan la comisión generada. No se cerró la liquidación.',
          )
        } else if (result.reason === 'sin_movimientos') {
          setCloseError('No hay movimientos pendientes para liquidar.')
        } else {
          setCloseError('La liquidación no se pudo cerrar.')
        }
        await reload()
        return
      }

      const paid = result.payout_amount ?? result.payout_due
      const advances = result.advances_deducted ?? result.advances_total

      setSelected(null)
      setPreview(null)
      setNotice(
        paid > 0
          ? `Liquidación cerrada. Pagaste ${formatMoney(paid)} a ${staffName}.`
          : advances > 0
            ? `Liquidación cerrada. Los adelantos cubrieron la comisión de ${staffName}.`
            : `Liquidación cerrada sin pago para ${staffName}.`,
      )
      await reload()
      onSettled()
    } catch (err) {
      setCloseError(
        err instanceof Error ? err.message : 'No pudimos cerrar la liquidación.',
      )
    } finally {
      setClosing(false)
    }
  }

  const canClose =
    preview !== null &&
    preview.income_count + preview.advances_count > 0 &&
    preview.payout_due >= 0

  return (
    <section aria-labelledby="settlements-heading">
      <button
        type="button"
        onClick={onBack}
        className="mb-3 inline-flex min-h-[44px] items-center gap-1.5 text-xs font-semibold text-muted hover:text-ink"
      >
        <ArrowLeft size={15} aria-hidden="true" />
        Volver a caja
      </button>

      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="settlements-heading" className="text-base font-bold">
            Liquidaciones
          </h2>
          <p className="mt-0.5 text-xs text-muted">
            Comisiones y adelantos pendientes por profesional.
          </p>
        </div>
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-base bg-surface text-muted">
          <HandCoins size={20} aria-hidden="true" />
        </span>
      </div>

      {notice && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-income/30 bg-income-soft px-3 py-2 text-xs font-medium text-income"
        >
          {notice}
        </p>
      )}

      {loading && (
        <p className="mt-6 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando saldos…
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

      {!loading && !error && ordered.length === 0 && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">No hay liquidaciones pendientes.</p>
          <p className="mt-1 text-xs text-muted">
            Cuando cobres turnos o registres adelantos, el saldo de cada profesional
            aparece acá.
          </p>
        </div>
      )}

      {!loading && !error && ordered.length > 0 && (
        <>
          <div className="mt-4 rounded-xl border border-strong bg-surface-alt/60 p-3">
            <div className="flex items-baseline justify-between gap-3">
              <span className="text-sm font-semibold">Total a pagar</span>
              <span className="numeric text-[clamp(0.875rem,4vw,1.125rem)] font-bold leading-tight">
                {formatMoney(totalPayable)}
              </span>
            </div>
            <div className="mt-2 grid grid-cols-2 gap-2 border-t border-base pt-2 text-xs">
              <div>
                <p className="text-muted">Comisiones</p>
                <p className="numeric mt-0.5 font-semibold text-income">
                  {formatMoney(totalCommission)}
                </p>
              </div>
              <div>
                <p className="text-muted">Adelantos</p>
                <p className="numeric mt-0.5 font-semibold text-expense">
                  {formatMoney(totalAdvances)}
                </p>
              </div>
            </div>
          </div>

          <ul className="mt-3 space-y-2">
            {ordered.map((row) => {
              const member = staff.find((item) => item.id === row.staff_id)
              const negative = row.balance_due < 0

              return (
                <li key={row.staff_id}>
                  <button
                    type="button"
                    onClick={() => openSettlement(row)}
                    className="flex min-h-[76px] w-full items-center justify-between gap-3 rounded-xl border border-base bg-surface p-3 text-left hover:bg-surface-alt/60"
                  >
                    <div className="flex min-w-0 items-start gap-2.5">
                      <span
                        aria-hidden="true"
                        className="mt-0.5 size-3 shrink-0 rounded-full border border-strong"
                        style={{ backgroundColor: member?.color_hex ?? '#5C5A54' }}
                      />
                      <div className="min-w-0">
                        <div className="flex flex-wrap items-center gap-2">
                          <p className="truncate text-sm font-semibold">{row.staff_name}</p>
                          {member && !member.is_active && (
                            <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                              Inactivo
                            </span>
                          )}
                        </div>
                        <p className="numeric mt-1 text-xs text-muted">
                          Comisión {formatMoney(row.pending_commission)} ·{' '}
                          {row.pending_income_count} cobros
                        </p>
                        <p className="numeric mt-0.5 text-xs text-muted">
                          Adelantos {formatMoney(row.pending_advances)}
                        </p>
                      </div>
                    </div>

                    <div className="flex shrink-0 items-center gap-1.5 text-right">
                      <div>
                        <p className="text-[10px] font-semibold uppercase tracking-wide text-muted">
                          {negative ? 'Saldo a favor' : 'A pagar'}
                        </p>
                        <p
                          className={`numeric mt-0.5 text-sm font-bold ${
                            negative ? 'text-expense' : 'text-ink'
                          }`}
                        >
                          {formatMoney(row.balance_due)}
                        </p>
                      </div>
                      <ChevronRight size={16} className="text-muted" aria-hidden="true" />
                    </div>
                  </button>
                </li>
              )
            })}
          </ul>

          <p className="mt-4 text-xs text-muted">
            Al cerrar, se marcan los cobros del período y todos los adelantos pendientes
            como liquidados, y se registra el pago en la caja.
          </p>
        </>
      )}

      <Modal
        open={selected !== null}
        title={selected ? `Liquidar a ${selected.staff_name}` : 'Liquidación'}
        onClose={closeModal}
      >
        {selected && (
          <div className="space-y-4">
            {previewLoading && (
              <p className="flex items-center gap-2 text-sm text-muted">
                <Loader2 size={16} className="animate-spin" aria-hidden="true" />
                Calculando saldo…
              </p>
            )}

            {!previewLoading && previewError && (
              <div className="rounded-lg border border-base bg-surface p-3">
                <p className="text-sm text-ink">{previewError}</p>
                <div className="mt-3">
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={() => setPreviewAttempt((value) => value + 1)}
                  >
                    Reintentar
                  </Button>
                </div>
              </div>
            )}

            {!previewLoading && !previewError && preview && (
              <>
                <div className="space-y-1.5 rounded-xl border border-base bg-surface-alt/50 p-3">
                  <SummaryRow
                    label={`Bruto (${preview.income_count} cobros)`}
                    value={formatMoney(preview.gross_total)}
                  />
                  <SummaryRow
                    label="Descuentos"
                    value={`- ${formatMoney(preview.discount_total)}`}
                    negative={preview.discount_total > 0}
                  />
                  <SummaryRow
                    label="Insumos"
                    value={`- ${formatMoney(preview.supply_total)}`}
                    negative={preview.supply_total > 0}
                  />
                  <SummaryRow
                    label="Base comisionable"
                    value={formatMoney(preview.net_base_total)}
                  />
                  <SummaryRow
                    label="Comisión profesional"
                    value={formatMoney(preview.commission_total)}
                  />
                  <SummaryRow
                    label={`Adelantos (${preview.advances_count})`}
                    value={`- ${formatMoney(preview.advances_total)}`}
                    negative={preview.advances_total > 0}
                  />
                  <SummaryRow
                    label={preview.payout_due < 0 ? 'Saldo a favor del local' : 'A pagar'}
                    value={formatMoney(preview.payout_due)}
                    negative={preview.payout_due < 0}
                    strong
                  />
                </div>

                {preview.payout_due < 0 && (
                  <p className="rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending">
                    Los adelantos superan la comisión por{' '}
                    {formatMoney(-preview.payout_due)}. No se puede cerrar hasta generar
                    comisiones suficientes.
                  </p>
                )}

                {preview.income_count + preview.advances_count === 0 && (
                  <p className="rounded-lg border border-base bg-surface p-3 text-xs text-muted">
                    No hay movimientos pendientes para este profesional.
                  </p>
                )}

                <div className="space-y-1.5">
                  <label htmlFor="settlement-payment" className="text-sm font-medium">
                    Medio de pago
                  </label>
                  <PaymentMethodSelect
                    id="settlement-payment"
                    value={paymentMethod}
                    onChange={setPaymentMethod}
                  />
                </div>

                <div className="space-y-1.5">
                  <label htmlFor="settlement-note" className="text-sm font-medium">
                    Nota <span className="font-normal text-muted">(opcional)</span>
                  </label>
                  <Input
                    id="settlement-note"
                    value={note}
                    onChange={(event) => setNote(event.target.value)}
                    maxLength={200}
                    placeholder="Ej. semana del 17 al 22"
                  />
                </div>

                <FieldError>{closeError}</FieldError>

                {confirming ? (
                  <div className="space-y-2 rounded-xl border border-pending/40 bg-pending-soft p-3">
                    <p className="text-xs font-medium text-pending">
                      Se marcarán {preview.income_count} cobros y{' '}
                      {preview.advances_count} adelantos como liquidados, y se registrará
                      un pago de {formatMoney(preview.payout_due)}.
                    </p>
                    <Button
                      type="button"
                      loading={closing}
                      disabled={!canClose}
                      onClick={() => void handleClose()}
                    >
                      Confirmar pago
                    </Button>
                    <Button
                      type="button"
                      variant="secondary"
                      disabled={closing}
                      onClick={() => setConfirming(false)}
                    >
                      Volver
                    </Button>
                  </div>
                ) : (
                  <div className="space-y-2">
                    <Button
                      type="button"
                      disabled={!canClose || closing}
                      onClick={() => setConfirming(true)}
                    >
                      Cerrar liquidación
                    </Button>
                    <Button
                      type="button"
                      variant="secondary"
                      onClick={closeModal}
                      disabled={closing}
                    >
                      Cancelar
                    </Button>
                  </div>
                )}

                <p className="text-xs text-muted">
                  Incluye todos los cobros y adelantos pendientes hasta hoy.
                </p>
              </>
            )}
          </div>
        )}
      </Modal>
    </section>
  )
}

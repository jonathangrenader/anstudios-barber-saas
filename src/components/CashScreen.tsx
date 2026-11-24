import { useMemo, useState } from 'react'
import {
  ChevronLeft,
  ChevronRight,
  HandCoins,
  Loader2,
  Plus,
  TrendingDown,
  Wallet,
} from 'lucide-react'
import { useAgenda } from '../hooks/useAgenda'
import { useCash } from '../hooks/useCash'
import { useCatalog } from '../hooks/useCatalog'
import { useStaff } from '../hooks/useStaff'
import {
  addDaysToDateKey,
  dateKeyLongLabel,
  shopDateKey,
  zonedTime,
} from '../lib/datetime'
import { formatMoney } from '../lib/format'
import type { CashMovementType, CashMovementView } from '../types/cash'
import type { Shop } from '../types/shop'
import { CashIncomeForm } from './CashIncomeForm'
import { CashOutflowForm } from './CashOutflowForm'
import { paymentMethodLabel } from './CashFormFields'
import { SettlementsScreen } from './SettlementsScreen'
import { Modal } from './ui/Modal'
import { Button } from './ui/controls'

const TYPE_META: Record<CashMovementType, { label: string; className: string }> = {
  income: { label: 'Cobro', className: 'bg-income-soft text-income' },
  expense: { label: 'Gasto', className: 'bg-expense-soft text-expense' },
  staff_advance: { label: 'Adelanto', className: 'bg-expense-soft text-expense' },
  commission_payout: { label: 'Liquidación', className: 'bg-surface-alt text-muted' },
}

function round2(value: number): number {
  return Math.round(value * 100) / 100
}

function MovementCard({
  movement,
  timezone,
}: {
  movement: CashMovementView
  timezone: string
}) {
  const meta = TYPE_META[movement.movement_type]
  const isIncome = movement.movement_type === 'income'
  const amount = isIncome
    ? movement.gross_amount - movement.discount_amount
    : movement.gross_amount
  const hasBreakdown =
    isIncome && (movement.discount_amount > 0 || movement.supply_deduction > 0)

  return (
    <li className="rounded-xl border border-base bg-surface p-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span
              className={`rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${meta.className}`}
            >
              {meta.label}
            </span>
            <span className="numeric text-[11px] text-muted">
              {zonedTime(movement.movement_date, timezone)}
            </span>
            {isIncome && movement.is_settled && (
              <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                Liquidado
              </span>
            )}
            {movement.sync_status && (
              <span
                className={`rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                  movement.sync_status === 'failed'
                    ? 'bg-expense-soft text-expense'
                    : 'bg-pending-soft text-pending'
                }`}
              >
                {movement.sync_status === 'failed' ? 'Error al sincronizar' : 'Guardado local'}
              </span>
            )}
          </div>

          <p className="mt-1 truncate text-sm font-semibold">{movement.description}</p>
          <p className="mt-0.5 truncate text-xs text-muted">
            {paymentMethodLabel(movement.payment_method)}
            {movement.staff ? ` · ${movement.staff.name}` : ''}
            {movement.item ? ` · ${movement.item.name}` : ''}
          </p>
          {movement.appointment && (
            <p className="mt-0.5 truncate text-xs text-muted">
              Turno de {movement.appointment.client_name_snapshot}
            </p>
          )}

          {hasBreakdown && (
            <p className="numeric mt-1 text-[11px] text-muted">
              Bruto {formatMoney(movement.gross_amount)} · Desc.{' '}
              {formatMoney(movement.discount_amount)} · Insumos{' '}
              {formatMoney(movement.supply_deduction)}
            </p>
          )}
        </div>

        <div className="shrink-0 text-right">
          <p
            className={`numeric text-sm font-bold ${
              isIncome ? 'text-income' : 'text-expense'
            }`}
          >
            {isIncome ? '+' : '-'}
            {formatMoney(amount)}
          </p>
          {isIncome && (
            <p className="numeric mt-1 text-[10px] text-muted">
              Comisión {formatMoney(movement.staff_commission_amount)}
            </p>
          )}
        </div>
      </div>

      {isIncome && (
        <div className="mt-2 flex items-center justify-between gap-2 border-t border-base pt-2 text-[11px] text-muted">
          <span>Neto local</span>
          <span className="numeric font-semibold text-ink">
            {formatMoney(movement.shop_net_amount)}
          </span>
        </div>
      )}
    </li>
  )
}

export function CashScreen({ shop, online }: { shop: Shop; online: boolean }) {
  const today = shopDateKey(new Date(), shop.timezone)
  const [dateKey, setDateKey] = useState(today)
  const [form, setForm] = useState<'income' | 'expense' | 'advance' | null>(null)
  const [screen, setScreen] = useState<'cash' | 'settlements'>('cash')
  const [notice, setNotice] = useState<string | null>(null)

  const { movements, loading, error, reload } = useCash(
    shop.id,
    dateKey,
    shop.timezone,
  )
  const { appointments } = useAgenda(shop.id, dateKey, shop.timezone)
  const { items } = useCatalog(shop.id)
  const { members } = useStaff(shop.id)

  const chargedAppointmentIds = useMemo(
    () =>
      new Set(
        movements
          .filter(
            (movement) =>
              movement.movement_type === 'income' && movement.appointment_id,
          )
          .map((movement) => movement.appointment_id as string),
      ),
    [movements],
  )

  const chargeableAppointments = appointments.filter(
    (appointment) =>
      appointment.status !== 'cancelled' &&
      appointment.status !== 'no_show' &&
      !chargedAppointmentIds.has(appointment.id),
  )

  const summary = useMemo(() => {
    let income = 0
    let expenses = 0
    let advances = 0
    let payouts = 0
    let pendingCommissions = 0

    for (const movement of movements) {
      if (movement.movement_type === 'income') {
        income += movement.gross_amount - movement.discount_amount
        if (!movement.is_settled) pendingCommissions += movement.staff_commission_amount
      } else if (movement.movement_type === 'expense') {
        expenses += movement.gross_amount
      } else if (movement.movement_type === 'staff_advance') {
        advances += movement.gross_amount
      } else {
        payouts += movement.gross_amount
      }
    }

    return {
      income: round2(income),
      expenses: round2(expenses),
      advances: round2(advances),
      payouts: round2(payouts),
      pendingCommissions: round2(pendingCommissions),
      net: round2(income - expenses - advances - payouts),
    }
  }, [movements])

  function moveDay(days: number) {
    setDateKey((current) => addDaysToDateKey(current, days))
    setNotice(null)
  }

  function handleSaved(message: string) {
    setForm(null)
    setNotice(message)
    void reload()
  }

  const unsyncedCount = movements.filter((movement) => movement.sync_status).length

  if (screen === 'settlements') {
    return (
      <SettlementsScreen
        shop={shop}
        staff={members}
        onBack={() => setScreen('cash')}
        onSettled={() => void reload()}
      />
    )
  }

  return (
    <section aria-labelledby="cash-heading">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="cash-heading" className="text-base font-bold">
            Caja
          </h2>
          <p className="mt-0.5 text-xs text-muted">Cobros, gastos y adelantos del día.</p>
        </div>
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-base bg-surface text-muted">
          <Wallet size={20} aria-hidden="true" />
        </span>
      </div>

      <div className="mt-4 flex items-center justify-between gap-2 rounded-xl border border-base bg-surface p-1.5">
        <button
          type="button"
          onClick={() => moveDay(-1)}
          aria-label="Día anterior"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronLeft size={18} aria-hidden="true" />
        </button>
        <button
          type="button"
          onClick={() => {
            setDateKey(today)
            setNotice(null)
          }}
          className="min-w-0 flex-1 rounded-lg px-1 py-1 text-center"
          aria-label={dateKey === today ? 'Hoy' : 'Volver a hoy'}
        >
          <span className="block truncate text-sm font-semibold">
            {dateKeyLongLabel(dateKey)}
          </span>
          <span className="text-[11px] text-muted">
            {dateKey === today ? 'Hoy' : 'Volver a hoy'}
          </span>
        </button>
        <button
          type="button"
          onClick={() => moveDay(1)}
          aria-label="Día siguiente"
          className="flex size-11 shrink-0 items-center justify-center rounded-lg text-muted hover:bg-surface-alt"
        >
          <ChevronRight size={18} aria-hidden="true" />
        </button>
      </div>

      <div className="mt-3 grid grid-cols-2 gap-2">
        <div className="rounded-xl border border-base bg-surface p-3">
          <p className="text-xs text-muted">Cobrado</p>
          <p className="numeric mt-1 text-[clamp(0.875rem,4vw,1.125rem)] font-bold leading-tight text-income">
            {formatMoney(summary.income)}
          </p>
        </div>
        <div className="rounded-xl border border-base bg-surface p-3">
          <p className="text-xs text-muted">Gastos</p>
          <p className="numeric mt-1 text-[clamp(0.875rem,4vw,1.125rem)] font-bold leading-tight text-expense">
            {formatMoney(summary.expenses)}
          </p>
        </div>
        <div className="rounded-xl border border-base bg-surface p-3">
          <p className="text-xs text-muted">Adelantos</p>
          <p className="numeric mt-1 text-[clamp(0.875rem,4vw,1.125rem)] font-bold leading-tight text-expense">
            {formatMoney(summary.advances)}
          </p>
        </div>
        <div className="rounded-xl border border-strong bg-surface-alt/60 p-3">
          <p className="text-xs text-muted">Neto del día</p>
          <p
            className={`numeric mt-1 text-[clamp(0.875rem,4vw,1.125rem)] font-bold leading-tight ${
              summary.net < 0 ? 'text-expense' : 'text-ink'
            }`}
          >
            {formatMoney(summary.net)}
          </p>
        </div>
      </div>

      {summary.pendingCommissions > 0 && (
        <p className="numeric mt-2 text-xs text-muted">
          Comisiones por liquidar: {formatMoney(summary.pendingCommissions)}
        </p>
      )}

      {unsyncedCount > 0 && (
        <p className="mt-2 rounded-lg border border-pending/30 bg-pending-soft px-3 py-2 text-xs font-medium text-pending">
          {unsyncedCount} {unsyncedCount === 1 ? 'movimiento' : 'movimientos'} sin
          sincronizar. Los montos son estimados hasta que la base los recalcule al
          reconectar.
        </p>
      )}

      <div className="mt-3 grid grid-cols-2 gap-2">
        <Button
          type="button"
          className="col-span-2"
          onClick={() => {
            setNotice(null)
            setForm('income')
          }}
        >
          <Plus size={16} aria-hidden="true" />
          Cobrar
        </Button>
        <Button
          type="button"
          variant="secondary"
          onClick={() => {
            setNotice(null)
            setForm('expense')
          }}
        >
          <TrendingDown size={16} aria-hidden="true" />
          Gasto
        </Button>
        <Button
          type="button"
          variant="secondary"
          onClick={() => {
            setNotice(null)
            setForm('advance')
          }}
        >
          <Plus size={16} aria-hidden="true" />
          Adelanto
        </Button>
      </div>

      <button
        type="button"
        onClick={() => {
          setNotice(null)
          setScreen('settlements')
        }}
        disabled={!online}
        className="mt-2 flex min-h-[60px] w-full items-center gap-3 rounded-xl border border-base bg-surface p-3 text-left hover:bg-surface-alt/60 disabled:cursor-not-allowed disabled:opacity-60"
      >
        <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-pending-soft text-pending">
          <HandCoins size={18} aria-hidden="true" />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-sm font-semibold">Liquidaciones</span>
          <span className="block text-xs text-muted">
            {online
              ? 'Comisiones y adelantos por profesional.'
              : 'Requiere conexión para calcular y cerrar.'}
          </span>
        </span>
        <ChevronRight size={16} className="shrink-0 text-muted" aria-hidden="true" />
      </button>

      {notice && (
        <p
          role="status"
          className="mt-3 rounded-lg border border-income/30 bg-income-soft px-3 py-2 text-xs font-medium text-income"
        >
          {notice}
        </p>
      )}

      {loading && (
        <p className="mt-5 flex items-center gap-2 text-sm text-muted">
          <Loader2 size={16} className="animate-spin" aria-hidden="true" />
          Cargando movimientos…
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

      {!loading && !error && movements.length === 0 && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">Todavía no hay movimientos este día.</p>
          <p className="mt-1 text-xs text-muted">
            Cobrá un turno o venta, o registrá un gasto o adelanto.
          </p>
        </div>
      )}

      {!loading && !error && movements.length > 0 && (
        <>
          <div className="mt-5 flex items-center justify-between gap-2">
            <h3 className="text-xs font-semibold uppercase tracking-[0.12em] text-muted">
              Movimientos · {movements.length}
            </h3>
            {summary.payouts > 0 && (
              <span className="numeric text-[11px] text-muted">
                Liquidaciones {formatMoney(summary.payouts)}
              </span>
            )}
          </div>
          <ul className="mt-2 space-y-2">
            {movements.map((movement) => (
              <MovementCard
                key={movement.id}
                movement={movement}
                timezone={shop.timezone}
              />
            ))}
          </ul>
        </>
      )}

      <Modal
        open={form !== null}
        title={
          form === 'income'
            ? 'Nuevo cobro'
            : form === 'expense'
              ? 'Nuevo gasto'
              : 'Nuevo adelanto'
        }
        onClose={() => setForm(null)}
      >
        {form === 'income' && (
          <CashIncomeForm
            shopId={shop.id}
            timezone={shop.timezone}
            dateKey={dateKey}
            appointments={chargeableAppointments}
            staff={members}
            items={items}
            onSaved={(message) =>
              handleSaved(message ?? 'Cobro registrado en la caja.')
            }
            onCancel={() => setForm(null)}
          />
        )}
        {(form === 'expense' || form === 'advance') && (
          <CashOutflowForm
            shopId={shop.id}
            timezone={shop.timezone}
            dateKey={dateKey}
            kind={form === 'expense' ? 'expense' : 'staff_advance'}
            staff={members}
            onSaved={(message) =>
              handleSaved(
                message ??
                  (form === 'expense'
                    ? 'Gasto registrado en la caja.'
                    : 'Adelanto registrado en la caja.'),
              )
            }
            onCancel={() => setForm(null)}
          />
        )}
      </Modal>
    </section>
  )
}

import { useEffect, useState } from 'react'
import { Check, Copy, KeyRound, Loader2, Pencil, Plus } from 'lucide-react'
import { useStaff } from '../hooks/useStaff'
import { formatPercent } from '../lib/format'
import type { StaffInput, StaffInvite, StaffMember } from '../types/staff'
import { CalendarFeedSection } from './CalendarFeedSection'
import { StaffForm } from './StaffForm'
import { Modal } from './ui/Modal'
import { Button } from './ui/controls'

function inviteCodeLabel(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`
}

async function copyText(value: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(value)
    return true
  } catch {
    return false
  }
}

function AccessSection({
  member,
  invite,
  busy,
  onRefresh,
  onUnlink,
}: {
  member: StaffMember
  invite: StaffInvite | undefined
  busy: boolean
  onRefresh: () => void
  onUnlink: () => void
}) {
  const [copied, setCopied] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [copyError, setCopyError] = useState<string | null>(null)

  async function handleCopy() {
    if (!invite) return
    setCopyError(null)
    if (await copyText(invite.code)) {
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } else {
      setCopyError('No pudimos copiar. Anotá el código manualmente.')
    }
  }

  if (member.user_id) {
    return (
      <div className="mt-2 border-t border-base pt-2">
        <p className="flex items-center gap-1.5 text-xs font-semibold text-income">
          <KeyRound size={13} aria-hidden="true" />
          Acceso vinculado
        </p>
        {confirming ? (
          <div className="mt-1.5 space-y-1.5">
            <p className="text-xs text-muted">
              La cuenta dejará de ver su agenda y el código actual no servirá.
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                onClick={onUnlink}
                disabled={busy}
                className="inline-flex min-h-[44px] items-center justify-center gap-2 rounded-lg border border-base bg-surface px-3 text-xs font-semibold text-expense hover:bg-expense-soft disabled:opacity-60"
              >
                {busy && <Loader2 size={14} className="animate-spin" aria-hidden="true" />}
                Desvincular
              </button>
              <button
                type="button"
                onClick={() => setConfirming(false)}
                disabled={busy}
                className="min-h-[44px] px-2 text-xs font-medium text-muted hover:text-ink"
              >
                Cancelar
              </button>
            </div>
          </div>
        ) : (
          <button
            type="button"
            onClick={() => setConfirming(true)}
            disabled={busy}
            className="min-h-[44px] text-xs font-medium text-muted underline-offset-4 hover:text-ink hover:underline"
          >
            Desvincular acceso
          </button>
        )}
      </div>
    )
  }

  return (
    <div className="mt-2 rounded-lg border border-base bg-surface-alt/50 px-2.5 py-2">
      <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-muted">
        Código de acceso
      </p>

      {invite ? (
        <>
          <div className="mt-1 flex items-center gap-2">
            <code className="numeric min-w-0 flex-1 text-base font-bold tracking-[0.16em]">
              {inviteCodeLabel(invite.code)}
            </code>
            <button
              type="button"
              onClick={() => void handleCopy()}
              className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-base bg-surface px-2.5 text-xs font-semibold text-ink hover:bg-surface-alt"
            >
              {copied ? (
                <Check size={14} className="text-income" aria-hidden="true" />
              ) : (
                <Copy size={14} aria-hidden="true" />
              )}
              {copied ? 'Copiado' : 'Copiar'}
            </button>
          </div>
          <p className="mt-1 text-[11px] leading-snug text-muted">
            El profesional crea su cuenta en esta app e ingresa el código una sola vez.
            Va a ver únicamente su propia agenda.
          </p>
          <button
            type="button"
            onClick={onRefresh}
            disabled={busy}
            className="mt-0.5 min-h-[44px] text-xs font-medium text-muted underline-offset-4 hover:text-ink hover:underline"
          >
            Generar otro código
          </button>
          {copyError && (
            <p role="alert" className="text-[11px] font-medium text-expense">
              {copyError}
            </p>
          )}
        </>
      ) : (
        <button
          type="button"
          onClick={onRefresh}
          disabled={busy}
          className="mt-1 min-h-[44px] text-xs font-semibold text-muted underline-offset-4 hover:text-ink hover:underline"
        >
          Generar código de acceso
        </button>
      )}
    </div>
  )
}

function StaffCard({
  member,
  invite,
  accessBusy,
  onEdit,
  onToggle,
  onRefreshInvite,
  onUnlink,
  collapseAllSignal,
  expandAllSignal,
}: {
  member: StaffMember
  invite: StaffInvite | undefined
  accessBusy: boolean
  onEdit: () => void
  onToggle: () => void
  onRefreshInvite: () => void
  onUnlink: () => void
  collapseAllSignal: number
  expandAllSignal: number
}) {
  const [collapsed, setCollapsed] = useState(true)

  useEffect(() => {
    setCollapsed(true)
  }, [collapseAllSignal])

  useEffect(() => {
    setCollapsed(false)
  }, [expandAllSignal])

  return (
    <li className="rounded-xl border border-base bg-surface p-3">
      <div className="flex items-start justify-between gap-2">
        <button
          type="button"
          onClick={() => setCollapsed((value) => !value)}
          aria-expanded={!collapsed}
          aria-label={collapsed ? `Expandir ${member.name}` : `Colapsar ${member.name}`}
          className="flex min-w-0 flex-1 items-start gap-2.5 text-left"
        >
          <span
            aria-hidden="true"
            className="mt-0.5 size-3 shrink-0 rounded-full border border-strong"
            style={{ backgroundColor: member.color_hex }}
          />
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <p className="truncate text-sm font-semibold">{member.name}</p>
              {!member.is_active && (
                <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-muted">
                  Inactivo
                </span>
              )}
              {member.user_id && (
                <span className="rounded bg-income-soft px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-income">
                  Acceso
                </span>
              )}
              {member.can_book_appointments && (
                <span className="rounded bg-surface-alt px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-ink">
                  Agenda
                </span>
              )}
            </div>
            <p className="mt-0.5 text-xs text-muted">{member.role}</p>
            {collapsed && (
              <p className="numeric mt-0.5 text-[11px] text-muted">
                Servicios {formatPercent(member.commission_pct)} · Productos{' '}
                {formatPercent(member.product_commission_pct)}
              </p>
            )}
          </div>
        </button>
        <div className="flex shrink-0 items-center gap-1">
          <button
            type="button"
            onClick={() => setCollapsed((value) => !value)}
            aria-label={collapsed ? 'Expandir' : 'Colapsar'}
            className="flex size-11 items-center justify-center rounded-lg border border-base text-muted hover:bg-surface-alt"
          >
            {collapsed ? '▸' : '▾'}
          </button>
          <button
            type="button"
            onClick={onEdit}
            aria-label={`Editar ${member.name}`}
            className="flex size-11 items-center justify-center rounded-lg border border-base text-muted hover:bg-surface-alt"
          >
            <Pencil size={16} aria-hidden="true" />
          </button>
        </div>
      </div>

      {!collapsed && (
        <>
          <p className="numeric mt-1 text-xs text-muted">
            Servicios {formatPercent(member.commission_pct)} · Productos{' '}
            {formatPercent(member.product_commission_pct)}
          </p>
          {member.phone && <p className="numeric mt-0.5 text-xs text-muted">{member.phone}</p>}

          <AccessSection
            member={member}
            invite={invite}
            busy={accessBusy}
            onRefresh={onRefreshInvite}
            onUnlink={onUnlink}
          />

          {member.is_active && <CalendarFeedSection staffId={member.id} />}

          <div className="mt-1 border-t border-base pt-1">
            <button
              type="button"
              onClick={onToggle}
              className="min-h-[44px] px-1 text-xs font-medium text-muted hover:text-ink"
            >
              {member.is_active ? 'Desactivar' : 'Activar'}
            </button>
          </div>
        </>
      )}
    </li>
  )
}

export function StaffScreen({ shopId }: { shopId: string }) {
  const {
    members,
    invites,
    loading,
    error,
    reload,
    save,
    toggleActive,
    refreshInvite,
    unlinkAccess,
  } = useStaff(shopId)
  const [formOpen, setFormOpen] = useState(false)
  const [editing, setEditing] = useState<StaffMember | null>(null)
  const [pending, setPending] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [accessBusyId, setAccessBusyId] = useState<string | null>(null)
  const [collapseAllSignal, setCollapseAllSignal] = useState(0)
  const [expandAllSignal, setExpandAllSignal] = useState(0)

  const invitesByStaff = new Map(invites.map((invite) => [invite.staff_id, invite]))

  function openCreate() {
    setEditing(null)
    setFormError(null)
    setFormOpen(true)
  }

  function openEdit(member: StaffMember) {
    setEditing(member)
    setFormError(null)
    setFormOpen(true)
  }

  async function handleSubmit(input: StaffInput) {
    setPending(true)
    setFormError(null)
    try {
      await save(input, editing?.id)
      setFormOpen(false)
    } catch (err) {
      setFormError(err instanceof Error ? err.message : 'No pudimos guardar al profesional.')
    } finally {
      setPending(false)
    }
  }

  async function handleToggle(member: StaffMember) {
    setActionError(null)
    try {
      await toggleActive(member)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'No pudimos completar la acción.')
    }
  }

  async function handleRefreshInvite(member: StaffMember) {
    setActionError(null)
    setAccessBusyId(member.id)
    try {
      await refreshInvite(member.id)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'No pudimos generar el código.')
    } finally {
      setAccessBusyId(null)
    }
  }

  async function handleUnlink(member: StaffMember) {
    setActionError(null)
    setAccessBusyId(member.id)
    try {
      await unlinkAccess(member.id)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'No pudimos desvincular el acceso.')
    } finally {
      setAccessBusyId(null)
    }
  }

  return (
    <section aria-labelledby="staff-heading">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 id="staff-heading" className="text-base font-bold">
            Equipo
          </h2>
          <p className="mt-0.5 text-xs text-muted">Profesionales y sus comisiones.</p>
        </div>
        <button
          type="button"
          onClick={openCreate}
          className="inline-flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-lg border border-strong bg-brand-primary px-3 text-sm font-semibold text-white shadow-tactile"
        >
          <Plus size={16} aria-hidden="true" />
          Agregar
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
          Cargando equipo…
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

      {!loading && !error && members.length === 0 && (
        <div className="mt-4 rounded-xl border border-base bg-surface p-4">
          <p className="text-sm font-medium">Todavía no hay profesionales.</p>
          <p className="mt-1 text-xs text-muted">
            Agregá a quien atiende para poder asignarle turnos y calcular su comisión.
          </p>
          <div className="mt-4">
            <Button type="button" onClick={openCreate}>
              Agregar el primero
            </Button>
          </div>
        </div>
      )}

      {members.length > 0 && (
        <div className="mt-3 flex flex-wrap gap-2">
          <button
            type="button"
            onClick={() => setExpandAllSignal((value) => value + 1)}
            className="min-h-[44px] rounded-lg border border-base bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-alt"
          >
            Expandir todos
          </button>
          <button
            type="button"
            onClick={() => setCollapseAllSignal((value) => value + 1)}
            className="min-h-[44px] rounded-lg border border-base bg-surface px-3 text-xs font-semibold text-ink hover:bg-surface-alt"
          >
            Colapsar todos
          </button>
        </div>
      )}

      {members.length > 0 && (
        <ul className="mt-4 space-y-2">
          {members.map((member) => (
            <StaffCard
              key={member.id}
              member={member}
              invite={invitesByStaff.get(member.id)}
              accessBusy={accessBusyId === member.id}
              onEdit={() => openEdit(member)}
              onToggle={() => void handleToggle(member)}
              onRefreshInvite={() => void handleRefreshInvite(member)}
              onUnlink={() => void handleUnlink(member)}
              collapseAllSignal={collapseAllSignal}
              expandAllSignal={expandAllSignal}
            />
          ))}
        </ul>
      )}

      <p className="mt-4 text-xs text-muted">
        Un profesional con historial no se elimina: se desactiva para conservar turnos y
        liquidaciones. El código de acceso le permite ver solo su propia agenda; caja,
        equipo y configuración siguen siendo del dueño.
      </p>

      <Modal
        open={formOpen}
        title={editing ? 'Editar profesional' : 'Nuevo profesional'}
        onClose={() => {
          if (!pending) setFormOpen(false)
        }}
      >
        <StaffForm
          member={editing}
          pending={pending}
          error={formError}
          onSubmit={(input) => void handleSubmit(input)}
          onCancel={() => setFormOpen(false)}
        />
      </Modal>
    </section>
  )
}

import { useCallback, useEffect, useState } from 'react'
import {
  createStaffMember,
  listStaff,
  listStaffInvites,
  refreshStaffInvite,
  unlinkStaffAccess,
  updateStaffMember,
} from '../lib/staff'
import type { StaffInput, StaffInvite, StaffMember } from '../types/staff'

export function useStaff(shopId: string) {
  const [members, setMembers] = useState<StaffMember[]>([])
  const [invites, setInvites] = useState<StaffInvite[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const [nextMembers, nextInvites] = await Promise.all([
        listStaff(shopId),
        // Los códigos son online-only: si fallan no bloquean el listado del equipo.
        listStaffInvites(shopId).catch(() => null),
      ])
      setMembers(nextMembers)
      if (nextInvites) setInvites(nextInvites)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos cargar el equipo.')
    } finally {
      setLoading(false)
    }
  }, [shopId])

  useEffect(() => {
    void reload()
  }, [reload])

  const save = useCallback(
    async (input: StaffInput, id?: string) => {
      if (id) await updateStaffMember(id, input)
      else await createStaffMember(shopId, input)
      await reload()
    },
    [shopId, reload],
  )

  const toggleActive = useCallback(
    async (member: StaffMember) => {
      await updateStaffMember(member.id, { is_active: !member.is_active })
      await reload()
    },
    [reload],
  )

  const refreshInvite = useCallback(
    async (staffId: string) => {
      await refreshStaffInvite(staffId)
      await reload()
    },
    [reload],
  )

  const unlinkAccess = useCallback(
    async (staffId: string) => {
      await unlinkStaffAccess(staffId)
      await reload()
    },
    [reload],
  )

  return {
    members,
    invites,
    loading,
    error,
    reload,
    save,
    toggleActive,
    refreshInvite,
    unlinkAccess,
  }
}

import { supabase } from './supabase'
import { dbErrorMessage } from './dbErrors'
import { cachedQuery } from './offline/cache'
import { cacheKeys } from './offline/keys'
import type {
  StaffAgendaItem,
  StaffContext,
  StaffInput,
  StaffInvite,
  StaffMember,
} from '../types/staff'

type StaffRow = Omit<StaffMember, 'commission_pct' | 'product_commission_pct'> & {
  commission_pct: number | string
  product_commission_pct: number | string
}

function mapStaff(row: StaffRow): StaffMember {
  return {
    ...row,
    commission_pct: Number(row.commission_pct),
    product_commission_pct: Number(row.product_commission_pct),
    can_book_appointments: row.can_book_appointments ?? false,
    working_days: row.working_days ?? null,
    work_start_time: row.work_start_time ?? null,
    work_end_time: row.work_end_time ?? null,
  }
}

export async function listStaff(shopId: string): Promise<StaffMember[]> {
  return cachedQuery(
    cacheKeys.staff(shopId),
    async () => {
      const { data, error } = await supabase
        .from('staff')
        // Sin `calendar_token`: el link se pide por RPC y no se guarda en el caché offline.
        .select(
          'id, shop_id, user_id, name, role, phone, commission_pct, product_commission_pct, is_active, color_hex, photo_url, bio, can_book_appointments, working_days, work_start_time, work_end_time, created_at',
        )
        .eq('shop_id', shopId)
        .order('is_active', { ascending: false })
        .order('name')

      if (error) throw new Error(dbErrorMessage(error, 'No pudimos cargar el equipo.'))
      return ((data ?? []) as StaffRow[]).map(mapStaff)
    },
    'Sin conexión y sin equipo guardado. Conectate una vez para poder consultarlo offline.',
  )
}

export async function createStaffMember(
  shopId: string,
  input: StaffInput,
): Promise<StaffMember> {
  const { data, error } = await supabase
    .from('staff')
    .insert({ ...input, shop_id: shopId })
    .select('*')
    .single()

  if (error) throw new Error(dbErrorMessage(error, 'No pudimos agregar al profesional.'))
  return mapStaff(data as StaffRow)
}

export async function updateStaffMember(
  id: string,
  patch: Partial<StaffInput>,
): Promise<void> {
  const { error } = await supabase.from('staff').update(patch).eq('id', id)
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos actualizar al profesional.'))
}

/** Códigos de acceso del equipo. Solo el dueño los ve (RLS). */
export async function listStaffInvites(shopId: string): Promise<StaffInvite[]> {
  const { data, error } = await supabase
    .from('staff_invites')
    .select('*')
    .eq('shop_id', shopId)

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos cargar los códigos de acceso.'))
  }
  return (data ?? []) as StaffInvite[]
}

/** Rota el código y desvincula la cuenta que lo hubiera usado. */
export async function refreshStaffInvite(staffId: string): Promise<string> {
  const { data, error } = await supabase.rpc('fn_refresh_staff_invite', {
    p_staff_id: staffId,
  })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos generar un código nuevo.'))
  }
  return data as string
}

export async function unlinkStaffAccess(staffId: string): Promise<string> {
  const { data, error } = await supabase.rpc('fn_unlink_staff_access', {
    p_staff_id: staffId,
  })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos desvincular el acceso.'))
  }
  return data as string
}

/** El profesional reclama su ficha con el código del dueño. */
export async function claimStaffInvite(code: string): Promise<StaffContext> {
  const { data, error } = await supabase.rpc('fn_claim_staff_invite', { p_code: code })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos validar el código.'))
  }
  return data as StaffContext
}

/** Ficha y local del profesional logueado. `null` si la cuenta no es de staff. */
export async function fetchStaffContext(): Promise<StaffContext | null> {
  const { data, error } = await supabase.rpc('fn_staff_context')

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos cargar tu acceso de profesional.'))
  }
  return (data as StaffContext | null) ?? null
}

/** Agenda propia del día; la base la calcula en la zona horaria del local. */
export async function fetchMyAgenda(dateKey: string): Promise<StaffAgendaItem[]> {
  const { data, error } = await supabase.rpc('fn_my_agenda', { p_date: dateKey })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos cargar tu agenda.'))
  }
  return (data ?? []) as StaffAgendaItem[]
}

/** El profesional mueve solo su turno: iniciar, completar o marcar ausencia. */
export async function setMyAppointmentStatus(
  appointmentId: string,
  status: 'in_progress' | 'completed' | 'no_show',
): Promise<void> {
  const { error } = await supabase.rpc('fn_set_my_appointment_status', {
    p_appointment_id: appointmentId,
    p_status: status,
  })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos actualizar el turno.'))
  }
}

/** Horarios de trabajo propios del profesional. */
export async function updateMySchedule(
  workingDays: number[] | null,
  workStart: string | null,
  workEnd: string | null,
): Promise<void> {
  const { error } = await supabase.rpc('fn_update_my_schedule', {
    p_working_days: workingDays,
    p_work_start: workStart,
    p_work_end: workEnd,
  })
  if (error) throw new Error(dbErrorMessage(error, 'No pudimos guardar tu agenda.'))
}

/** Foto y descripción propias del profesional. */
export async function updateMyProfile(photoUrl: string | null, bio: string): Promise<void> {
  const { error } = await supabase.rpc('fn_update_my_profile', {
    p_photo_url: photoUrl,
    p_bio: bio,
  })

  if (error) {
    throw new Error(dbErrorMessage(error, 'No pudimos guardar tu perfil.'))
  }
}

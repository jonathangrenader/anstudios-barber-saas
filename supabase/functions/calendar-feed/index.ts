// Edge Function: feed ICS de solo lectura por profesional (T-020).
// Se despliega con `supabase functions deploy calendar-feed --no-verify-jwt`
// porque Google Calendar lo consulta sin JWT (la autorización es el token).
//
// GET /functions/v1/calendar-feed?token=<staff.calendar_token>
// Devuelve los turnos del profesional entre -90 y +90 días como text/calendar.
// Privacidad: solo nombre del cliente y servicio; nunca teléfono ni notas.

import { createClient } from 'npm:@supabase/supabase-js@2'

const WINDOW_DAYS = 90
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const encoder = new TextEncoder()

type AppointmentRow = {
  id: string
  starts_at: string
  ends_at: string
  status: string
  client_name_snapshot: string
  catalog_items: { name: string } | { name: string }[] | null
}

function notFound(): Response {
  return new Response('Calendario no encontrado', {
    status: 404,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  })
}

function escapeIcs(value: string): string {
  return value
    .replace(/\\/g, '\\\\')
    .replace(/\r?\n/g, '\\n')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
}

/** Pliega líneas a 75 octetos como exige RFC 5545. */
function foldLine(line: string): string {
  const parts: string[] = []
  let current = ''
  let bytes = 0
  for (const char of line) {
    const size = encoder.encode(char).length
    if (bytes + size > 73) {
      parts.push(current)
      current = ' '
      bytes = 1
    }
    current += char
    bytes += size
  }
  parts.push(current)
  return parts.join('\r\n')
}

function utcStamp(iso: string): string {
  return `${new Date(iso).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '')}`
}

function serviceName(appointment: AppointmentRow): string {
  const item = Array.isArray(appointment.catalog_items)
    ? appointment.catalog_items[0]
    : appointment.catalog_items
  return item?.name?.trim() || 'Turno'
}

function eventFor(appointment: AppointmentRow): string {
  const cancelled = appointment.status === 'cancelled'
  const noShow = appointment.status === 'no_show'
  const service = serviceName(appointment)
  const suffix = noShow ? ' (no asistió)' : ''
  const summary = `${service} · ${appointment.client_name_snapshot}${suffix}`

  const lines = [
    'BEGIN:VEVENT',
    `UID:${appointment.id}@anstudios`,
    `DTSTAMP:${utcStamp(new Date().toISOString())}`,
    `DTSTART:${utcStamp(appointment.starts_at)}`,
    `DTEND:${utcStamp(appointment.ends_at)}`,
    `SUMMARY:${escapeIcs(summary)}`,
    `DESCRIPTION:${escapeIcs(
      `Cliente: ${appointment.client_name_snapshot}\nServicio: ${service}`,
    )}`,
    cancelled ? 'STATUS:CANCELLED' : 'STATUS:CONFIRMED',
    'TRANSP:OPAQUE',
    'END:VEVENT',
  ]
  return lines.map(foldLine).join('\r\n')
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response('Método no permitido', {
      status: 405,
      headers: { Allow: 'GET, HEAD' },
    })
  }

  const token = new URL(req.url).searchParams.get('token') ?? ''
  if (!UUID_RE.test(token)) return notFound()

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceRoleKey) {
    console.error('calendar-feed: faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY')
    return new Response('Feed no configurado', { status: 500 })
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: staff, error: staffError } = await supabase
    .from('staff')
    .select('id, name, is_active, shops(name, timezone, is_suspended, trial_ends_at)')
    .eq('calendar_token', token)
    .maybeSingle()

  if (staffError) {
    console.error('calendar-feed: error al buscar profesional', staffError.message)
    return new Response('Error al generar el calendario', { status: 500 })
  }
  if (!staff || !staff.is_active) return notFound()

  const shop = Array.isArray(staff.shops) ? staff.shops[0] : staff.shops
  const shopBlocked =
    !shop ||
    shop.is_suspended ||
    (shop.trial_ends_at !== null && new Date(shop.trial_ends_at).getTime() <= Date.now())
  if (shopBlocked) return notFound()

  const now = Date.now()
  const from = new Date(now - WINDOW_DAYS * 86_400_000).toISOString()
  const to = new Date(now + WINDOW_DAYS * 86_400_000).toISOString()

  const { data: appointments, error: appointmentsError } = await supabase
    .from('appointments')
    .select(
      'id, starts_at, ends_at, status, client_name_snapshot, catalog_items(name)',
    )
    .eq('staff_id', staff.id)
    .gte('starts_at', from)
    .lte('starts_at', to)
    .order('starts_at', { ascending: true })

  if (appointmentsError) {
    console.error('calendar-feed: error al leer turnos', appointmentsError.message)
    return new Response('Error al generar el calendario', { status: 500 })
  }

  const lines = [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//ANSTUDIOS//Turnos//ES',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    `X-WR-CALNAME:${escapeIcs(`ANSTUDIOS — ${staff.name}`)}`,
    `X-WR-CALDESC:${escapeIcs(
      `Turnos de ${staff.name}${shop?.name ? ` en ${shop.name}` : ''}`,
    )}`,
    ...(shop?.timezone ? [`X-WR-TIMEZONE:${shop.timezone}`] : []),
    ...(appointments ?? []).map((appointment) =>
      eventFor(appointment as unknown as AppointmentRow),
    ),
    'END:VCALENDAR',
  ]

  const body = `${lines.join('\r\n')}\r\n`
  const headers: Record<string, string> = {
    'Content-Type': 'text/calendar; charset=utf-8',
    'Content-Disposition': 'inline; filename="anstudios.ics"',
    // Google refresca los feeds externos cada varias horas; 15 min de caché es seguro.
    'Cache-Control': 'public, max-age=900',
  }
  return new Response(req.method === 'HEAD' ? null : body, { status: 200, headers })
})

import { dateKeyLongLabel, shopDateKey, zonedTime } from './datetime'
import type { AppointmentView } from '../types/appointment'
import type { Shop } from '../types/shop'

/**
 * Normaliza un teléfono argentino al formato que espera `wa.me`:
 * solo dígitos, con código de país 54 y 9 de móvil cuando el número
 * viene en formato local (10 dígitos).
 */
export function toWhatsAppPhone(raw: string): string | null {
  let digits = raw.replace(/\D/g, '')

  if (digits.startsWith('00')) digits = digits.slice(2)
  if (digits.startsWith('0')) digits = digits.replace(/^0+/, '')
  if (digits.length < 10 || digits.length > 15) return null

  if (digits.startsWith('54')) {
    const rest = digits.slice(2).replace(/^0+/, '')
    // 54 + área + número sin el 9 de móvil.
    if (rest.length === 10) return `549${rest}`
    // 54 + 9 + área + número.
    if (rest.length === 11 && rest.startsWith('9')) return `54${rest}`
    // Formatos ambiguos (por ejemplo 0 + 15) se rechazan en vez de abrir un chat equivocado.
    return null
  }

  // 11 2345-6789 -> 549 11 2345-6789
  if (digits.length === 10) return `549${digits}`

  // 9 11 2345-6789 (móvil sin código de país).
  if (digits.length === 11 && digits.startsWith('9')) return `54${digits}`

  return null
}

export function buildReminderMessage(shop: Shop, appointment: AppointmentView): string {
  const firstName = appointment.client_name_snapshot.trim().split(/\s+/)[0] || 'hola'
  const dateKey = shopDateKey(new Date(appointment.starts_at), shop.timezone)
  const dateLabel = dateKeyLongLabel(dateKey).toLocaleLowerCase('es-AR').replace(',', '')
  const time = zonedTime(appointment.starts_at, shop.timezone)
  const service = appointment.service?.name
  const staff = appointment.staff?.name

  const lines = [
    `Hola ${firstName}, te recuerdo tu turno en ${shop.name} para el ${dateLabel} a las ${time} hs.`,
  ]

  if (service || staff) {
    lines.push(
      [service ? `Servicio: ${service}` : null, staff ? `Profesional: ${staff}` : null]
        .filter(Boolean)
        .join(' · '),
    )
  }

  if (shop.address) lines.push(`Dirección: ${shop.address}`)
  lines.push('Si no podés asistir, avisanos por acá.')

  return lines.join('\n')
}

export function buildReminderUrl(shop: Shop, appointment: AppointmentView): string | null {
  const phone = toWhatsAppPhone(appointment.client_phone_snapshot)
  if (!phone) return null
  return `https://wa.me/${phone}?text=${encodeURIComponent(buildReminderMessage(shop, appointment))}`
}

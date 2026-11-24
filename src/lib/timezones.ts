export const DEFAULT_TIMEZONE = 'America/Argentina/Buenos_Aires'

const FALLBACK = [
  'America/Argentina/Buenos_Aires',
  'America/Argentina/Cordoba',
  'America/Argentina/Mendoza',
  'America/Argentina/Salta',
  'America/Argentina/Tucuman',
  'America/Argentina/Jujuy',
  'America/Argentina/San_Juan',
  'America/Argentina/San_Luis',
  'America/Argentina/La_Rioja',
  'America/Argentina/Catamarca',
  'America/Argentina/Rio_Gallegos',
  'America/Argentina/Ushuaia',
]

let cache: string[] | null = null

export function argentinaTimezones(): string[] {
  if (cache) return cache

  const intl = Intl as unknown as { supportedValuesOf?: (key: string) => string[] }
  const supported = (intl.supportedValuesOf?.('timeZone') ?? []).filter((tz) =>
    tz.startsWith('America/Argentina/'),
  )

  // Unión para que ninguna zona argentina falte aunque el navegador no la exponga.
  const zones = Array.from(new Set([DEFAULT_TIMEZONE, ...supported, ...FALLBACK]))
  zones.sort((a, b) => timezoneLabel(a).localeCompare(timezoneLabel(b), 'es'))

  // Buenos Aires siempre primera: es la opción por defecto del formulario.
  const defaultIndex = zones.indexOf(DEFAULT_TIMEZONE)
  if (defaultIndex > 0) {
    const [buenosAires] = zones.splice(defaultIndex, 1)
    zones.unshift(buenosAires)
  }

  cache = zones
  return cache
}

export function timezoneLabel(timezone: string): string {
  return timezone.replace('America/Argentina/', '').replace(/_/g, ' ')
}

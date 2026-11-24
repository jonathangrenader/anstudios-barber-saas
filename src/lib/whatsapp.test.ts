import { describe, expect, it } from 'vitest'
import { toWhatsAppPhone } from './whatsapp'

describe('toWhatsAppPhone', () => {
  it('convierte un número local de 10 dígitos con el 9 de móvil', () => {
    expect(toWhatsAppPhone('11 2345-6789')).toBe('5491123456789')
    expect(toWhatsAppPhone('(011) 2345 6789')).toBe('5491123456789')
  })

  it('acepta 54 + área + número sin 9 y agrega el 9', () => {
    expect(toWhatsAppPhone('+54 11 2345 6789')).toBe('5491123456789')
  })

  it('respeta 54 + 9 + área + número', () => {
    expect(toWhatsAppPhone('+54 9 11 2345-6789')).toBe('5491123456789')
  })

  it('acepta móvil sin código de país', () => {
    expect(toWhatsAppPhone('9 11 2345 6789')).toBe('5491123456789')
  })

  it('rechaza formatos ambiguos o demasiado cortos', () => {
    expect(toWhatsAppPhone('2345-6789')).toBeNull()
    expect(toWhatsAppPhone('011 15 2345 6789')).toBeNull()
    expect(toWhatsAppPhone('')).toBeNull()
    expect(toWhatsAppPhone('1234567890123456')).toBeNull()
  })
})

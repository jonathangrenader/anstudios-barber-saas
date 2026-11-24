const money = new Intl.NumberFormat('es-AR', {
  style: 'currency',
  currency: 'ARS',
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
})

const percent = new Intl.NumberFormat('es-AR', { maximumFractionDigits: 2 })

export function formatMoney(value: number): string {
  return money.format(Number.isFinite(value) ? value : 0)
}

export function formatPercent(value: number): string {
  return `${percent.format(Number.isFinite(value) ? value : 0)}%`
}

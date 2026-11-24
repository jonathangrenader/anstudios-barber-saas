/** @type {import('tailwindcss').Config} */
const token = (name) => `rgb(var(--c-${name}) / <alpha-value>)`

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        canvas: token('canvas'),
        surface: token('surface'),
        'surface-alt': token('surface-alt'),
        base: token('border'),
        strong: token('ink'),
        ink: token('ink'),
        muted: token('muted'),
        'brand-primary': token('brand'),
        'brand-accent': token('accent'),
        income: { DEFAULT: token('income'), soft: token('income-soft') },
        expense: { DEFAULT: token('expense'), soft: token('expense-soft') },
        pending: { DEFAULT: token('pending'), soft: token('pending-soft') },
      },
      fontFamily: {
        sans: ['"Plus Jakarta Sans"', 'system-ui', 'sans-serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'monospace'],
      },
      boxShadow: {
        tactile: '2px 2px 0 var(--c-shadow)',
      },
    },
  },
  plugins: [],
}

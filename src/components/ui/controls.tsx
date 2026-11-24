import type {
  ButtonHTMLAttributes,
  InputHTMLAttributes,
  SelectHTMLAttributes,
  TextareaHTMLAttributes,
} from 'react'
import { Loader2 } from 'lucide-react'

const controlBase =
  'min-h-[44px] w-full rounded-lg border border-base bg-surface px-3 text-sm text-ink placeholder:text-muted/60 transition-colors focus:border-strong focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-primary disabled:opacity-60'

export function Input({ className = '', ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...props} className={`${controlBase} ${className}`} />
}

export function Select({
  className = '',
  ...props
}: SelectHTMLAttributes<HTMLSelectElement>) {
  return <select {...props} className={`${controlBase} pr-8 ${className}`} />
}

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'secondary' | 'danger'
  loading?: boolean
}

export function Button({
  variant = 'primary',
  loading = false,
  className = '',
  children,
  disabled,
  ...props
}: ButtonProps) {
  const styles =
    variant === 'primary'
      ? 'border-strong bg-brand-primary text-white shadow-tactile'
      : variant === 'danger'
        ? 'border-base bg-surface text-expense hover:bg-expense-soft'
        : 'border-base bg-surface text-ink hover:bg-surface-alt'

  return (
    <button
      {...props}
      disabled={disabled || loading}
      className={`inline-flex min-h-[44px] w-full items-center justify-center gap-2 rounded-lg border px-4 text-sm font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-60 ${styles} ${className}`}
    >
      {loading && <Loader2 size={16} className="animate-spin" aria-hidden="true" />}
      {children}
    </button>
  )
}

export function Textarea({
  className = '',
  ...props
}: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      {...props}
      className={`min-h-[88px] w-full rounded-lg border border-base bg-surface px-3 py-2.5 text-sm text-ink placeholder:text-muted/60 transition-colors focus:border-strong focus:outline-none focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-primary disabled:opacity-60 ${className}`}
    />
  )
}

export function Checkbox({
  label,
  ...props
}: InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  return (
    <label className="flex min-h-[44px] cursor-pointer items-center gap-3 text-sm">
      <input
        type="checkbox"
        {...props}
        className="size-5 shrink-0 accent-brand-primary"
      />
      <span>{label}</span>
    </label>
  )
}

export function FieldError({ children }: { children: string | null }) {
  if (!children) return null
  return (
    <p role="alert" className="text-xs font-medium text-expense">
      {children}
    </p>
  )
}

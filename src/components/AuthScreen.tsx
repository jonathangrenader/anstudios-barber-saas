import { useState, type FormEvent } from 'react'
import { Scissors } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { Button, FieldError, Input } from './ui/controls'

type Mode = 'login' | 'register'

function translateAuthError(message: string): string {
  const text = message.toLowerCase()

  if (text.includes('invalid login credentials')) return 'Email o contraseña incorrectos.'
  if (text.includes('email not confirmed')) {
    return 'Confirmá tu email antes de ingresar. Revisá tu bandeja de entrada.'
  }
  if (text.includes('user already registered')) {
    return 'Ya existe una cuenta con ese email. Iniciá sesión.'
  }
  if (text.includes('password should be at least')) {
    return 'La contraseña debe tener al menos 6 caracteres.'
  }
  if (text.includes('unable to validate email')) return 'El email no parece válido.'
  if (text.includes('rate limit') || text.includes('for security purposes')) {
    return 'Demasiados intentos seguidos. Esperá unos minutos y volvé a probar.'
  }

  return message
}

export function AuthScreen() {
  const [mode, setMode] = useState<Mode>('login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  function changeMode(next: Mode) {
    setMode(next)
    setError(null)
    setNotice(null)
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    setNotice(null)
    setPending(true)

    try {
      if (mode === 'login') {
        const { error: authError } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        })
        if (authError) {
          setError(translateAuthError(authError.message))
        }
      } else {
        const { data, error: authError } = await supabase.auth.signUp({
          email: email.trim(),
          password,
        })
        if (authError) {
          setError(translateAuthError(authError.message))
        } else if (!data.session) {
          setNotice('Cuenta creada. Te enviamos un correo para confirmar el email antes de ingresar.')
        }
      }
    } catch {
      setError('No pudimos conectar con el servidor. Revisá tu conexión e intentá de nuevo.')
    } finally {
      setPending(false)
    }
  }

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center gap-6 px-5 py-10">
      <header className="flex items-start gap-3">
        <span className="flex size-11 shrink-0 items-center justify-center rounded-xl border border-strong bg-brand-primary text-white">
          <Scissors size={22} strokeWidth={2} aria-hidden="true" />
        </span>
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.14em] text-muted">ANSTUDIOS</p>
          <h1 className="text-2xl font-bold leading-tight">Tu local, en orden.</h1>
          <p className="mt-1 text-sm text-muted">
            Turnos, caja y comisiones en un solo lugar.
          </p>
        </div>
      </header>

      <section className="rounded-xl border border-base bg-surface p-4 sm:p-5">
        <div className="mb-5 grid grid-cols-2 gap-1 rounded-lg border border-base bg-surface-alt p-1">
          <button
            type="button"
            onClick={() => changeMode('login')}
            aria-pressed={mode === 'login'}
            className={`min-h-[40px] rounded-md text-sm font-semibold transition-colors ${
              mode === 'login' ? 'border border-strong bg-surface text-ink' : 'text-muted'
            }`}
          >
            Ingresar
          </button>
          <button
            type="button"
            onClick={() => changeMode('register')}
            aria-pressed={mode === 'register'}
            className={`min-h-[40px] rounded-md text-sm font-semibold transition-colors ${
              mode === 'register' ? 'border border-strong bg-surface text-ink' : 'text-muted'
            }`}
          >
            Crear cuenta
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4" noValidate>
          <div className="space-y-1.5">
            <label htmlFor="auth-email" className="text-sm font-medium">
              Email
            </label>
            <Input
              id="auth-email"
              type="email"
              inputMode="email"
              autoComplete="email"
              placeholder="vos@tulocal.com"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              required
            />
          </div>

          <div className="space-y-1.5">
            <label htmlFor="auth-password" className="text-sm font-medium">
              Contraseña
            </label>
            <Input
              id="auth-password"
              type="password"
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              placeholder="Mínimo 6 caracteres"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              minLength={6}
              required
            />
          </div>

          <FieldError>{error}</FieldError>

          {notice && (
            <p
              role="status"
              className="rounded-lg border border-income/30 bg-income-soft px-3 py-2 text-xs font-medium text-income"
            >
              {notice}
            </p>
          )}

          <Button type="submit" loading={pending}>
            {mode === 'login' ? 'Ingresar' : 'Crear cuenta'}
          </Button>
        </form>
      </section>

      <div className="space-y-2 text-center text-xs text-muted">
        <p>
          ¿Trabajás en un local?{' '}
          <button
            type="button"
            onClick={() => changeMode('register')}
            className="font-semibold text-ink underline underline-offset-4"
          >
            Creá tu cuenta
          </button>{' '}
          con tu email y después ingresá el código de acceso que te dieron.
        </p>
        <p>Cada local ve únicamente sus propios datos.</p>
      </div>
    </main>
  )
}

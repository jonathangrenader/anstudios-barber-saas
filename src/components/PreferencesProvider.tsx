import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'

export type Theme = 'light' | 'dark'
export type TextSize = 'compact' | 'normal' | 'large'

const THEME_KEY = 'anstudios.theme'
const TEXT_SIZE_KEY = 'anstudios.text-size'
const THEME_COLORS: Record<Theme, string> = {
  light: '#F7F5F0',
  dark: '#151412',
}

function readStored<T extends string>(key: string, allowed: readonly T[]): T | null {
  try {
    const value = window.localStorage.getItem(key)
    return value && (allowed as readonly string[]).includes(value) ? (value as T) : null
  } catch {
    return null
  }
}

function initialTheme(): Theme {
  const stored = readStored(THEME_KEY, ['light', 'dark'] as const)
  if (stored) return stored
  return window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

interface PreferencesValue {
  theme: Theme
  textSize: TextSize
  setTheme: (theme: Theme) => void
  setTextSize: (size: TextSize) => void
}

const PreferencesContext = createContext<PreferencesValue | null>(null)

export function PreferencesProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<Theme>(initialTheme)
  const [textSize, setTextSizeState] = useState<TextSize>(
    () => readStored(TEXT_SIZE_KEY, ['compact', 'normal', 'large'] as const) ?? 'normal',
  )

  useEffect(() => {
    const root = document.documentElement
    root.dataset.theme = theme
    root.dataset.textSize = textSize
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', THEME_COLORS[theme])
  }, [theme, textSize])

  const setTheme = useCallback((next: Theme) => {
    setThemeState(next)
    try {
      window.localStorage.setItem(THEME_KEY, next)
    } catch {
      /* almacenamiento no disponible */
    }
  }, [])

  const setTextSize = useCallback((next: TextSize) => {
    setTextSizeState(next)
    try {
      window.localStorage.setItem(TEXT_SIZE_KEY, next)
    } catch {
      /* almacenamiento no disponible */
    }
  }, [])

  const value = useMemo(
    () => ({ theme, textSize, setTheme, setTextSize }),
    [theme, textSize, setTheme, setTextSize],
  )

  return <PreferencesContext.Provider value={value}>{children}</PreferencesContext.Provider>
}

export function usePreferences(): PreferencesValue {
  const value = useContext(PreferencesContext)
  if (!value) throw new Error('usePreferences debe usarse dentro de PreferencesProvider')
  return value
}

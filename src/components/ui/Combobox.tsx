import { useEffect, useRef, useState, type KeyboardEvent } from 'react'
import { Check, ChevronDown } from 'lucide-react'
import { Input } from './controls'

export type ComboboxOption = { value: string; label: string }

type ComboboxProps = {
  id: string
  value: string
  options: ComboboxOption[]
  onChange: (value: string) => void
  placeholder?: string
  invalid?: boolean
}

/** Búsqueda insensible a mayúsculas y tildes. */
function fold(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
}

export function Combobox({
  id,
  value,
  options,
  onChange,
  placeholder = 'Buscar…',
  invalid = false,
}: ComboboxProps) {
  const [open, setOpen] = useState(false)
  // null = mostrar la etiqueta seleccionada; string = texto que está escribiendo el usuario.
  const [query, setQuery] = useState<string | null>(null)
  const [activeIndex, setActiveIndex] = useState(0)
  const containerRef = useRef<HTMLDivElement>(null)
  const activeRef = useRef<HTMLLIElement>(null)

  const selected = options.find((option) => option.value === value)
  const search = query?.trim() ?? ''
  const filtered = search
    ? options.filter(
        (option) =>
          fold(option.label).includes(fold(search)) || fold(option.value).includes(fold(search)),
      )
    : options
  const activeOption = filtered[activeIndex]
  const listId = `${id}-listbox`

  useEffect(() => {
    if (!open) return

    function handlePointerDown(event: MouseEvent) {
      if (!containerRef.current?.contains(event.target as Node)) setOpen(false)
    }

    document.addEventListener('mousedown', handlePointerDown)
    return () => document.removeEventListener('mousedown', handlePointerDown)
  }, [open])

  useEffect(() => {
    if (open) activeRef.current?.scrollIntoView({ block: 'nearest' })
  }, [open, activeIndex])

  function openList() {
    setQuery(null)
    setActiveIndex(0)
    setOpen(true)
  }

  function select(option: ComboboxOption) {
    onChange(option.value)
    setQuery(null)
    setOpen(false)
  }

  function handleKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      if (!open) {
        openList()
        return
      }
      setActiveIndex((index) => Math.min(index + 1, filtered.length - 1))
      return
    }

    if (event.key === 'ArrowUp') {
      event.preventDefault()
      if (open) setActiveIndex((index) => Math.max(index - 1, 0))
      return
    }

    if (event.key === 'Home' && open) {
      event.preventDefault()
      setActiveIndex(0)
      return
    }

    if (event.key === 'End' && open) {
      event.preventDefault()
      setActiveIndex(Math.max(filtered.length - 1, 0))
      return
    }

    if (event.key === 'Enter') {
      if (open && activeOption) {
        event.preventDefault()
        select(activeOption)
      }
      return
    }

    if (event.key === 'Escape') {
      if (open) {
        event.preventDefault()
        setOpen(false)
      }
      return
    }

    if (event.key === 'Tab') setOpen(false)
  }

  return (
    <div ref={containerRef} className="relative">
      <Input
        id={id}
        type="text"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-activedescendant={open && activeOption ? `${id}-option-${activeIndex}` : undefined}
        aria-invalid={invalid}
        autoComplete="off"
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        placeholder={placeholder}
        value={query ?? selected?.label ?? ''}
        onChange={(event) => {
          setQuery(event.target.value)
          setActiveIndex(0)
          setOpen(true)
        }}
        onFocus={(event) => {
          openList()
          event.currentTarget.select()
        }}
        onClick={() => {
          if (!open) openList()
        }}
        onKeyDown={handleKeyDown}
        onBlur={() => {
          setOpen(false)
          setQuery(null)
        }}
        className="pr-10"
      />

      <ChevronDown
        size={16}
        aria-hidden="true"
        className={`pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 text-muted transition-transform ${
          open ? 'rotate-180' : ''
        }`}
      />

      {open && (
        <ul
          id={listId}
          role="listbox"
          aria-label="Opciones"
          onMouseDown={(event) => event.preventDefault()}
          className="absolute inset-x-0 z-30 mt-1 max-h-60 overflow-y-auto rounded-lg border border-strong bg-surface p-1"
        >
          {filtered.length === 0 && (
            <li className="px-3 py-3 text-sm text-muted">Sin resultados.</li>
          )}

          {filtered.map((option, index) => {
            const isSelected = option.value === value
            const isActive = index === activeIndex

            return (
              <li
                key={option.value}
                ref={isActive ? activeRef : undefined}
                id={`${id}-option-${index}`}
                role="option"
                aria-selected={isSelected}
                onClick={() => select(option)}
                onMouseEnter={() => setActiveIndex(index)}
                className={`flex min-h-[44px] cursor-pointer items-center justify-between gap-2 rounded-md px-3 text-sm ${
                  isActive ? 'bg-surface-alt' : ''
                } ${isSelected ? 'font-semibold text-ink' : 'text-ink'}`}
              >
                <span className="truncate">{option.label}</span>
                {isSelected && (
                  <Check size={16} className="shrink-0 text-brand-primary" aria-hidden="true" />
                )}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}

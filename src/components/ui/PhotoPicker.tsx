import { useId, useState } from 'react'
import { ImagePlus, Loader2, Trash2 } from 'lucide-react'
import { uploadImage } from '../../lib/storage'

export function PhotoPicker({
  label,
  prefix,
  value,
  onChange,
  disabled = false,
}: {
  label: string
  prefix: string
  value: string | null
  onChange: (url: string | null) => void
  disabled?: boolean
}) {
  const inputId = useId()
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleFile(file: File | undefined) {
    if (!file) return
    setUploading(true)
    setError(null)
    try {
      onChange(await uploadImage(prefix, file))
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No pudimos subir la imagen.')
    } finally {
      setUploading(false)
    }
  }

  return (
    <div>
      <p className="text-xs font-medium text-muted">{label}</p>
      <div className="mt-1.5 flex items-center gap-3">
        <div className="flex size-16 shrink-0 items-center justify-center overflow-hidden rounded-lg border border-base bg-surface-alt">
          {value ? (
            <img src={value} alt="" className="size-full object-cover" />
          ) : (
            <ImagePlus size={20} className="text-muted" aria-hidden="true" />
          )}
        </div>
        <div className="min-w-0 flex-1 space-y-1.5">
          <div className="flex flex-wrap gap-1.5">
            <label
              htmlFor={inputId}
              className={`inline-flex min-h-[44px] cursor-pointer items-center gap-2 rounded-lg border border-base bg-surface px-3 text-xs font-semibold hover:bg-surface-alt ${
                disabled || uploading ? 'pointer-events-none opacity-60' : ''
              }`}
            >
              {uploading ? (
                <Loader2 size={15} className="animate-spin" aria-hidden="true" />
              ) : (
                <ImagePlus size={15} aria-hidden="true" />
              )}
              {value ? 'Cambiar foto' : 'Subir foto'}
            </label>
            <input
              id={inputId}
              type="file"
              accept="image/jpeg,image/png,image/webp"
              className="sr-only"
              disabled={disabled || uploading}
              onChange={(event) => {
                void handleFile(event.target.files?.[0])
                event.target.value = ''
              }}
            />
            {value && (
              <button
                type="button"
                onClick={() => onChange(null)}
                disabled={disabled || uploading}
                className="inline-flex min-h-[44px] items-center gap-1.5 rounded-lg border border-base bg-surface px-3 text-xs font-semibold text-expense hover:bg-expense-soft disabled:opacity-60"
              >
                <Trash2 size={14} aria-hidden="true" />
                Quitar
              </button>
            )}
          </div>
          <p className="text-[11px] text-muted">JPG, PNG o WebP · hasta 5 MB.</p>
        </div>
      </div>
      {error && (
        <p role="alert" className="mt-1 text-xs font-medium text-expense">
          {error}
        </p>
      )}
    </div>
  )
}

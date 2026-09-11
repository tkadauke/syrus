import { useEffect, useMemo, useState, type ReactNode } from "react"
import { CloseIcon } from "@app/components/CloseIcon"
import { CopyIcon } from "@app/components/CopyableSlug"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"

export type MediaPreviewAction = {
  label: string
  href?: string | null
  download?: boolean
  copyValue?: string | null
}

export type MediaPreviewMeta = {
  label: string
  value: string | null | undefined
  copyValue?: string | null
}

export type MediaPreviewItem = {
  title: string
  subtitle?: string | null
  src?: string | null
  alt?: string | null
  badge?: string | null
  fallbackLabel?: string | null
  actions?: MediaPreviewAction[]
  meta?: MediaPreviewMeta[]
  previewChildren?: ReactNode
}

export function MediaPreviewShell({
  item,
  hasNext = false,
  hasPrevious = false,
  thumbnailClassName = "w-56",
  modalLabel = "media preview",
  onNext,
  onOpenChange,
  onPrevious,
  open
}: {
  hasNext?: boolean
  hasPrevious?: boolean
  item: MediaPreviewItem
  thumbnailClassName?: string
  modalLabel?: string
  onNext?: () => void
  onOpenChange?: (open: boolean) => void
  onPrevious?: () => void
  open?: boolean
}) {
  const [internalOpen, setInternalOpen] = useState(false)
  const isOpen = open ?? internalOpen
  const visibleMeta = useMemo(() => (item.meta ?? []).filter((row) => row.value), [item.meta])
  const setOpen = (nextOpen: boolean) => {
    if (open === undefined) setInternalOpen(nextOpen)
    onOpenChange?.(nextOpen)
  }

  return (
    <>
      <button
        aria-label={`Open ${item.title}`}
        className={`group/media block max-w-full overflow-hidden rounded border border-gray-200 bg-white p-0 text-left shadow-sm transition hover:border-brand/40 focus:outline-none focus:ring-2 focus:ring-brand dark:border-gray-800 dark:bg-gray-950 ${thumbnailClassName}`}
        onClick={() => setOpen(true)}
        type="button"
      >
        <span className="block aspect-video w-full overflow-hidden bg-gray-100 dark:bg-gray-900">
          {item.src ? (
            <img alt={item.alt ?? item.title} className="h-full w-full object-contain transition group-hover/media:scale-[1.02]" loading="lazy" src={item.src} />
          ) : (
            <span className="flex h-full w-full items-center justify-center px-3 text-center text-xs font-semibold uppercase text-gray-500 dark:text-gray-300">
              {item.fallbackLabel ?? "Preview"}
            </span>
          )}
        </span>
        <span className="block truncate px-2 pt-1 text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{item.title}</span>
        {item.subtitle || item.badge ? (
          <span className="flex items-center justify-between gap-2 px-2 pb-1 text-2xs text-gray-500 dark:text-gray-400">
            {item.subtitle ? <span className="truncate" title={item.subtitle}>{item.subtitle}</span> : <span />}
            {item.badge ? <span className="shrink-0 rounded-full bg-gray-100 px-1.5 py-0.5 uppercase dark:bg-gray-800">{item.badge}</span> : null}
          </span>
        ) : null}
      </button>
      {isOpen ? (
        <MediaPreviewModal
          hasNext={hasNext}
          hasPrevious={hasPrevious}
          item={item}
          modalLabel={modalLabel}
          onClose={() => setOpen(false)}
          onNext={onNext}
          onPrevious={onPrevious}
          visibleMeta={visibleMeta}
        />
      ) : null}
    </>
  )
}

function MediaPreviewModal({
  hasNext,
  hasPrevious,
  item,
  modalLabel,
  onClose,
  onNext,
  onPrevious,
  visibleMeta
}: {
  hasNext: boolean
  hasPrevious: boolean
  item: MediaPreviewItem
  modalLabel: string
  onClose: () => void
  onNext?: () => void
  onPrevious?: () => void
  visibleMeta: MediaPreviewMeta[]
}) {
  const showNavigation = Boolean(onPrevious && onNext && (hasPrevious || hasNext))

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") onClose()
      if (targetAcceptsText(event.target)) return
      if (event.key === "ArrowLeft" && hasPrevious) {
        event.preventDefault()
        onPrevious?.()
      }
      if (event.key === "ArrowRight" && hasNext) {
        event.preventDefault()
        onNext?.()
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [hasNext, hasPrevious, onClose, onNext, onPrevious])

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onClose} role="presentation">
      <section
        aria-label={modalLabel}
        aria-modal="true"
        className="relative flex max-h-full w-[min(960px,100vw-2rem)] flex-col overflow-hidden rounded bg-white shadow-lg dark:bg-gray-900"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <div className="flex items-start justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
          <div className="min-w-0">
            <h3 className="truncate text-sm font-semibold text-gray-900 dark:text-gray-100">{item.title}</h3>
            {item.subtitle ? <p className="mt-0.5 truncate text-xs text-gray-500 dark:text-gray-400">{item.subtitle}</p> : null}
          </div>
          <button
            aria-label="Close media preview"
            className="rounded bg-white/90 p-1.5 text-gray-600 shadow hover:bg-white hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <div className="min-h-0 overflow-auto p-4">
          <div className="relative flex min-h-48 items-center justify-center rounded border border-gray-200 bg-gray-50 dark:border-gray-800 dark:bg-gray-950">
            {showNavigation ? (
              <>
                <button
                  aria-label="Previous image"
                  className="absolute left-2 top-1/2 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded bg-white/90 text-2xl leading-none text-gray-700 shadow transition hover:bg-white hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-40 dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
                  disabled={!hasPrevious}
                  onClick={onPrevious}
                  type="button"
                >
                  <span aria-hidden="true">‹</span>
                </button>
                <button
                  aria-label="Next image"
                  className="absolute right-2 top-1/2 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded bg-white/90 text-2xl leading-none text-gray-700 shadow transition hover:bg-white hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand disabled:cursor-not-allowed disabled:opacity-40 dark:bg-gray-900/90 dark:text-gray-200 dark:hover:bg-gray-900"
                  disabled={!hasNext}
                  onClick={onNext}
                  type="button"
                >
                  <span aria-hidden="true">›</span>
                </button>
              </>
            ) : null}
            {item.previewChildren ? item.previewChildren : item.src ? (
              <img alt={item.alt ?? item.title} className="max-h-[calc(100dvh-16rem)] max-w-full object-contain" src={item.src} />
            ) : (
              <div className="px-4 py-8 text-center text-xs text-gray-500 dark:text-gray-400">{item.fallbackLabel ?? "No preview is available."}</div>
            )}
          </div>
          {visibleMeta.length > 0 ? (
            <dl className="mt-3 grid gap-2 text-xs sm:grid-cols-2">
              {visibleMeta.map((row) => <MediaPreviewMetaRow key={row.label} row={row} />)}
            </dl>
          ) : null}
          {item.actions && item.actions.length > 0 ? (
            <div className="mt-3 flex flex-wrap gap-2">
              {item.actions.map((action) => <MediaPreviewActionButton action={action} key={`${action.label}-${action.href ?? action.copyValue ?? ""}`} />)}
            </div>
          ) : null}
        </div>
      </section>
    </div>
  )
}

function targetAcceptsText(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  const tagName = target.tagName.toLowerCase()
  return tagName === "input" || tagName === "textarea" || tagName === "select"
}

function MediaPreviewMetaRow({ row }: { row: MediaPreviewMeta }) {
  const { copied, copy } = useCopyToClipboard()
  const copyValue = row.copyValue ?? row.value ?? null

  return (
    <div className="min-w-0 rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <dt className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{row.label}</dt>
      <dd className="mt-0.5 flex min-w-0 items-center gap-2">
        <span className="min-w-0 break-words font-mono text-gray-800 dark:text-gray-200">{row.value}</span>
        {copyValue ? (
          <button
            aria-label={`Copy ${row.label}`}
            className="shrink-0 rounded p-1 text-gray-400 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-brand dark:hover:bg-gray-800 dark:hover:text-gray-200"
            onClick={() => copy(copyValue)}
            title={copied ? "Copied" : `Copy ${row.label}`}
            type="button"
          >
            <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-green-600 dark:text-green-300" : ""}`} />
          </button>
        ) : null}
      </dd>
    </div>
  )
}

function MediaPreviewActionButton({ action }: { action: MediaPreviewAction }) {
  const { copied, copy } = useCopyToClipboard()

  if (action.copyValue) {
    return (
      <button
        className="rounded border border-gray-200 px-2 py-1 text-2xs font-semibold uppercase text-gray-600 hover:border-brand/50 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:border-gray-700 dark:text-gray-300 dark:hover:text-gray-100"
        onClick={() => copy(action.copyValue ?? "")}
        title={copied ? "Copied" : action.label}
        type="button"
      >
        {copied ? "Copied" : action.label}
      </button>
    )
  }

  if (!action.href) return null

  return (
    <a
      className="rounded border border-gray-200 px-2 py-1 text-2xs font-semibold uppercase text-gray-600 hover:border-brand/50 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-brand dark:border-gray-700 dark:text-gray-300 dark:hover:text-gray-100"
      download={action.download ? true : undefined}
      href={action.href}
      rel="noreferrer"
      target="_blank"
    >
      {action.label}
    </a>
  )
}

import { useEffect, useRef, useState } from "react"
import type { CSSProperties, KeyboardEvent, PointerEvent } from "react"
import type { BeforeAfterVisualImage } from "../../api/artifacts"
import { useT } from "../../hooks/useT"
import { CloseIcon } from "../CloseIcon"
import { Modal } from "../Modal"

type ComparisonProps = {
  before: BeforeAfterVisualImage
  after: BeforeAfterVisualImage
  title: string
}

const DRAG_THRESHOLD = 6
const SWIPE_THRESHOLD = 40
// Keep the 44px handle and its focus ring inside the clipped comparison frame
// even when the actual divider reaches either image edge.
const comparisonClasses = "relative isolate w-full cursor-pointer select-none overflow-hidden rounded border border-border bg-surface-subtle touch-none"
const sliderClasses =
  "absolute left-[clamp(1.625rem,var(--comparison-position),calc(100%_-_1.625rem))] top-1/2 flex h-11 w-11 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize items-center justify-center rounded-full border-2 border-white bg-text-primary/80 text-sm font-bold text-surface shadow focus:outline-none focus:ring-2 focus:ring-brand focus:ring-offset-2"
const modalClasses = "flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-surface shadow-2xl sm:h-[min(90dvh,60rem)] sm:w-[min(94dvw,80rem)] sm:rounded-lg"
const navigationButtonClasses =
  "rounded border border-border px-3 py-2 text-sm text-text-primary hover:bg-surface-subtle focus:outline-none focus:ring-2 focus:ring-brand"

function clamp(value: number) {
  return Math.min(100, Math.max(0, value))
}

export function BeforeAfterVisualComparison({ before, after, title }: ComparisonProps) {
  const { t } = useT("jobs")
  const [position, setPosition] = useState(50)
  const [previewOpen, setPreviewOpen] = useState(false)
  const frameRef = useRef<HTMLDivElement>(null)
  const gesture = useRef<{ pointerId: number; startX: number; dragged: boolean } | null>(null)

  if (!before?.image_url || !after?.image_url) return null

  function positionFromClientX(clientX: number) {
    const bounds = frameRef.current?.getBoundingClientRect()
    if (!bounds?.width) return
    setPosition(clamp(((clientX - bounds.left) / bounds.width) * 100))
  }

  function onPointerDown(event: PointerEvent<HTMLDivElement>) {
    if (event.button !== 0) return
    gesture.current = { pointerId: event.pointerId, startX: event.clientX, dragged: false }
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  function onPointerMove(event: PointerEvent<HTMLDivElement>) {
    const current = gesture.current
    if (!current || current.pointerId !== event.pointerId) return
    if (Math.abs(event.clientX - current.startX) >= DRAG_THRESHOLD) current.dragged = true
    if (current.dragged) positionFromClientX(event.clientX)
  }

  function onPointerUp(event: PointerEvent<HTMLDivElement>) {
    const current = gesture.current
    if (!current || current.pointerId !== event.pointerId) return
    gesture.current = null
    event.currentTarget.releasePointerCapture?.(event.pointerId)
    if (current.dragged) positionFromClientX(event.clientX)
    else setPreviewOpen(true)
  }

  function onSliderKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      event.stopPropagation()
      setPreviewOpen(true)
      return
    }

    let next = position
    if (event.key === "ArrowLeft" || event.key === "ArrowDown") next -= 2
    else if (event.key === "ArrowRight" || event.key === "ArrowUp") next += 2
    else if (event.key === "PageDown") next -= 10
    else if (event.key === "PageUp") next += 10
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = 100
    else return

    event.preventDefault()
    event.stopPropagation()
    setPosition(clamp(next))
  }

  return (
    <>
      <div
        aria-label={t("artifact_visual_comparison_open", { title })}
        className={comparisonClasses}
        data-testid="visual-comparison"
        onPointerCancel={() => {
          gesture.current = null
        }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={onPointerUp}
        ref={frameRef}
      >
        <img
          alt={t("artifact_visual_after_alt", { title: after.title || title })}
          className="block h-auto w-full object-contain"
          draggable={false}
          src={after.image_url}
        />
        <div
          className="absolute inset-0 overflow-hidden motion-reduce:transition-none"
          data-testid="visual-before-layer"
          style={{ clipPath: `inset(0 0 0 ${position}%)` }}
        >
          <img
            alt={t("artifact_visual_before_alt", { title: before.title || title })}
            className="block h-full w-full object-contain"
            draggable={false}
            src={before.image_url}
          />
        </div>
        <span className="absolute left-2 top-2 rounded bg-black/70 px-2 py-1 text-[11px] font-semibold text-white">{t("artifact_diff_after")}</span>
        <span className="absolute right-2 top-2 rounded bg-black/70 px-2 py-1 text-[11px] font-semibold text-white">{t("artifact_diff_before")}</span>
        <div className="pointer-events-none absolute inset-y-0 w-0.5 bg-white shadow-[0_0_0_1px_rgba(0,0,0,.35)]" style={{ left: `${position}%` }} />
        <div
          aria-label={t("artifact_visual_slider", { title })}
          aria-orientation="horizontal"
          aria-valuemax={100}
          aria-valuemin={0}
          aria-valuenow={Math.round(position)}
          className={sliderClasses}
          data-testid="visual-comparison-handle"
          onKeyDown={onSliderKeyDown}
          role="slider"
          style={{ "--comparison-position": `${position}%` } as CSSProperties}
          tabIndex={0}
        >
          <span aria-hidden="true">↔</span>
        </div>
      </div>
      {previewOpen ? <VisualComparisonPreview after={after} before={before} onClose={() => setPreviewOpen(false)} title={title} /> : null}
    </>
  )
}

function VisualComparisonPreview({ before, after, title, onClose }: ComparisonProps & { onClose: () => void }) {
  const { t } = useT("jobs")
  const images = [
    { image: after, label: t("artifact_diff_after") },
    { image: before, label: t("artifact_diff_before") }
  ]
  const [index, setIndex] = useState(0)
  const swipe = useRef<{ pointerId: number; startX: number } | null>(null)
  const current = images[index]
  const previous = () => setIndex((value) => (value + images.length - 1) % images.length)
  const next = () => setIndex((value) => (value + 1) % images.length)

  useEffect(() => {
    function onKeyDown(event: globalThis.KeyboardEvent) {
      if (event.key === "ArrowLeft") {
        event.preventDefault()
        previous()
      } else if (event.key === "ArrowRight") {
        event.preventDefault()
        next()
      }
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  })

  function onSwipeEnd(event: PointerEvent<HTMLDivElement>) {
    const start = swipe.current
    swipe.current = null
    if (!start || start.pointerId !== event.pointerId) return
    const distance = event.clientX - start.startX
    if (Math.abs(distance) < SWIPE_THRESHOLD) return
    if (distance < 0) next()
    else previous()
  }

  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/70 p-0 sm:items-center sm:p-4"
      className={modalClasses}
      label={t("artifact_visual_preview_label", { title })}
      onClose={onClose}
      open
    >
      <header className="flex shrink-0 items-center gap-3 border-b border-border px-4 py-3">
        <h2 className="min-w-0 flex-1 truncate text-sm font-semibold text-text-primary">{title}</h2>
        <span className="rounded bg-surface-subtle px-2 py-1 text-xs font-semibold text-text-secondary">{current.label}</span>
        <button
          aria-label={t("artifact_visual_close")}
          className="rounded p-2 text-text-secondary hover:bg-surface-subtle focus:outline-none focus:ring-2 focus:ring-brand"
          onClick={onClose}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </header>
      <div
        className="flex min-h-0 flex-1 touch-none items-center justify-center overflow-hidden bg-black p-3 sm:p-6"
        data-testid="visual-preview-swipe-area"
        onPointerCancel={() => {
          swipe.current = null
        }}
        onPointerDown={(event) => {
          swipe.current = { pointerId: event.pointerId, startX: event.clientX }
          event.currentTarget.setPointerCapture?.(event.pointerId)
        }}
        onPointerUp={onSwipeEnd}
      >
        <img
          alt={`${current.label}: ${current.image.title || title}`}
          className="max-h-full max-w-full object-contain motion-reduce:transition-none"
          src={current.image.image_url}
        />
      </div>
      <footer className="flex shrink-0 items-center justify-between border-t border-border px-4 py-3">
        <button className={navigationButtonClasses} onClick={previous} type="button">
          {t("artifact_visual_previous")}
        </button>
        <span className="text-xs text-text-secondary">{t("artifact_visual_position", { current: index + 1, total: images.length })}</span>
        <button className={navigationButtonClasses} onClick={next} type="button">
          {t("artifact_visual_next")}
        </button>
      </footer>
    </Modal>
  )
}

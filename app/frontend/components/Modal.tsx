import { useEffect, useRef } from "react"
import type { MouseEvent as ReactMouseEvent, ReactNode, RefObject } from "react"
import { createPortal } from "react-dom"

export interface ModalProps {
  open: boolean
  onClose: () => void
  children: ReactNode
  className?: string
  label?: string
  labelledBy?: string
  closeOnBackdropClick?: boolean
  closeOnEscape?: boolean
  initialFocusRef?: RefObject<HTMLElement | null>
}

const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'

// Shared modal/dialog primitive: portal, backdrop, escape-key close,
// backdrop-click close, and a basic focus trap in one place instead of
// each caller (ConfirmDialog, AddRepositoryModal, ConfigureAgentModal,
// GithubTokenModal, GeminiSetupSheet, ImageAnnotationModal,
// FilePreviewModal, DocumentPreviewModal, …) reimplementing its own
// copy-pasted keydown listener and backdrop div.
export function Modal({
  open,
  onClose,
  children,
  className = "",
  label,
  labelledBy,
  closeOnBackdropClick = true,
  closeOnEscape = true,
  initialFocusRef
}: ModalProps) {
  const panelRef = useRef<HTMLDivElement>(null)
  const previouslyFocusedRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return

    previouslyFocusedRef.current = document.activeElement as HTMLElement | null

    const target = initialFocusRef?.current ?? panelRef.current?.querySelector<HTMLElement>(FOCUSABLE_SELECTOR) ?? panelRef.current
    target?.focus()

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        if (closeOnEscape) onClose()
        return
      }

      if (event.key !== "Tab") return

      const panel = panelRef.current
      if (!panel) return

      const focusable = Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR))
      if (focusable.length === 0) {
        event.preventDefault()
        return
      }

      const first = focusable[0]
      const last = focusable[focusable.length - 1]

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener("keydown", onKeyDown)
    return () => {
      document.removeEventListener("keydown", onKeyDown)
      previouslyFocusedRef.current?.focus?.()
    }
  }, [open, onClose, closeOnEscape, initialFocusRef])

  if (!open) return null

  function onBackdropClick(event: ReactMouseEvent<HTMLDivElement>) {
    if (event.target !== event.currentTarget) return
    if (closeOnBackdropClick) onClose()
  }

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onBackdropClick} role="presentation">
      <div
        aria-label={labelledBy ? undefined : label}
        aria-labelledby={labelledBy}
        aria-modal="true"
        className={`w-full max-w-sm rounded-lg bg-surface p-5 shadow-xl ${className}`.trim()}
        ref={panelRef}
        role="dialog"
        tabIndex={-1}
      >
        {children}
      </div>
    </div>,
    document.body
  )
}

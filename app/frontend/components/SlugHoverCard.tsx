import { FloatingPortal, autoPlacement, flip, offset, useFloating } from "@floating-ui/react"
import { type ReactNode, useCallback, useRef, useState } from "react"
import { EpicPreviewCard } from "./EpicPreviewCard"
import { JobPreviewCard } from "./JobPreviewCard"

interface SlugHoverCardProps {
  kind: "job" | "epic"
  id: number
  children: ReactNode
}

function detectPointerFine(): boolean {
  return typeof window !== "undefined" && window.matchMedia("(hover: hover) and (pointer: fine)").matches
}

export function SlugHoverCard({ kind, id, children }: SlugHoverCardProps) {
  const [isOpen, setIsOpen] = useState(false)
  const openTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const closeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Checked once on first render; pointer capability doesn't change during a session
  const canHover = useRef(detectPointerFine())

  const { refs, floatingStyles } = useFloating({
    middleware: [offset(8), flip(), autoPlacement()],
  })

  const handleReferenceEnter = useCallback(() => {
    if (!canHover.current) return
    if (closeTimer.current) clearTimeout(closeTimer.current)
    openTimer.current = setTimeout(() => setIsOpen(true), 300)
  }, [])

  const handleReferenceLeave = useCallback(() => {
    if (!canHover.current) return
    if (openTimer.current) clearTimeout(openTimer.current)
    // Small grace period so the cursor can reach the floating card
    closeTimer.current = setTimeout(() => setIsOpen(false), 100)
  }, [])

  const handleFloatingEnter = useCallback(() => {
    if (closeTimer.current) clearTimeout(closeTimer.current)
  }, [])

  const handleFloatingLeave = useCallback(() => {
    setIsOpen(false)
  }, [])

  return (
    <>
      <span
        onMouseEnter={handleReferenceEnter}
        onMouseLeave={handleReferenceLeave}
        ref={refs.setReference}
        style={{ display: "inline" }}
      >
        {children}
      </span>
      {isOpen && (
        <FloatingPortal>
          <div
            onMouseEnter={handleFloatingEnter}
            onMouseLeave={handleFloatingLeave}
            ref={refs.setFloating}
            style={{ ...floatingStyles, zIndex: 50 }}
          >
            {kind === "job" ? <JobPreviewCard id={id} /> : <EpicPreviewCard id={id} />}
          </div>
        </FloatingPortal>
      )}
    </>
  )
}

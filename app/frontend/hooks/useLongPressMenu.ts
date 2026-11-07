import { useEffect, useRef, useState } from "react"
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent, RefObject } from "react"

const LONG_PRESS_MS = 500
const MOVEMENT_TOLERANCE_PX = 10
const OPEN_EVENT = "syrus:message-actions-open"

type LongPressTargetProps = {
  onContextMenu: (event: ReactMouseEvent<HTMLElement>) => void
  onPointerCancel: () => void
  onPointerDown: (event: ReactPointerEvent<HTMLElement>) => void
  onPointerMove: (event: ReactPointerEvent<HTMLElement>) => void
  onPointerUp: () => void
}

export function useLongPressMenu(enabled = true): {
  close: () => void
  menuRef: RefObject<HTMLDivElement>
  open: boolean
  targetProps: LongPressTargetProps
} {
  const [open, setOpen] = useState(false)
  const idRef = useRef(Symbol("message-actions"))
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const startRef = useRef<{ x: number; y: number } | null>(null)
  const recognizedRef = useRef(false)
  const menuRef = useRef<HTMLDivElement>(null)

  function clearGesture() {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = null
    startRef.current = null
  }

  function close() {
    setOpen(false)
  }

  useEffect(() => {
    function handleOtherMenu(event: Event) {
      if ((event as CustomEvent).detail !== idRef.current) close()
    }

    function handleOutsidePointer(event: PointerEvent) {
      if (menuRef.current?.contains(event.target as Node)) return
      close()
    }

    window.addEventListener(OPEN_EVENT, handleOtherMenu)
    document.addEventListener("pointerdown", handleOutsidePointer)
    return () => {
      clearGesture()
      window.removeEventListener(OPEN_EVENT, handleOtherMenu)
      document.removeEventListener("pointerdown", handleOutsidePointer)
    }
  }, [])

  useEffect(() => {
    if (!open) return
    menuRef.current?.querySelector<HTMLButtonElement>("button")?.focus()
  }, [open])

  function onPointerDown(event: ReactPointerEvent<HTMLElement>) {
    if (!enabled || (event.pointerType !== "touch" && event.pointerType !== "pen")) return
    if ((event.target as Element).closest("a, button, input, textarea, select, [contenteditable=true]")) return

    clearGesture()
    recognizedRef.current = false
    startRef.current = { x: event.clientX, y: event.clientY }
    timerRef.current = setTimeout(() => {
      recognizedRef.current = true
      setOpen(true)
      window.dispatchEvent(new CustomEvent(OPEN_EVENT, { detail: idRef.current }))
    }, LONG_PRESS_MS)
  }

  function onPointerMove(event: ReactPointerEvent<HTMLElement>) {
    const start = startRef.current
    if (!start) return
    if (Math.hypot(event.clientX - start.x, event.clientY - start.y) > MOVEMENT_TOLERANCE_PX) clearGesture()
  }

  function onContextMenu(event: ReactMouseEvent<HTMLElement>) {
    if (!recognizedRef.current) return
    event.preventDefault()
    recognizedRef.current = false
  }

  return {
    close,
    menuRef,
    open,
    targetProps: {
      onContextMenu,
      onPointerCancel: clearGesture,
      onPointerDown,
      onPointerMove,
      onPointerUp: clearGesture
    }
  }
}

import { type RefObject, useEffect, useRef } from "react"

// extraRef covers content rendered through a portal (e.g. a floating-ui
// FloatingPortal) that is outside `ref`'s DOM subtree but should still count
// as "inside" the popup for outside-pointer dismissal.
export function useDismissiblePopup<T extends HTMLElement>(open: boolean, onClose: () => void, extraRef?: RefObject<HTMLElement | null>) {
  const ref = useRef<T>(null)

  useEffect(() => {
    if (!open) return

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }

    function closeOnOutsidePointer(event: PointerEvent) {
      const target = event.target
      if (!(target instanceof Node)) {
        onClose()
        return
      }
      if (ref.current?.contains(target)) return
      if (extraRef?.current?.contains(target)) return

      onClose()
    }

    window.addEventListener("keydown", closeOnEscape)
    window.addEventListener("pointerdown", closeOnOutsidePointer)
    return () => {
      window.removeEventListener("keydown", closeOnEscape)
      window.removeEventListener("pointerdown", closeOnOutsidePointer)
    }
  }, [open, onClose])

  return ref
}

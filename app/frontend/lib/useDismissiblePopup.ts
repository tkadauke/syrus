import { useEffect, useRef, type RefObject } from "react"

const NO_EXTRA_REFS: ReadonlyArray<RefObject<HTMLElement | null>> = []

// extraRefs lets a caller whose trigger element lives outside the popup's own
// subtree (e.g. a portaled dropdown, where the toggle button and the menu are
// no longer DOM ancestors of each other) exempt that trigger from counting as
// an "outside" click.
export function useDismissiblePopup<T extends HTMLElement>(
  open: boolean,
  onClose: () => void,
  extraRefs: ReadonlyArray<RefObject<HTMLElement | null>> = NO_EXTRA_REFS
) {
  const ref = useRef<T>(null)

  useEffect(() => {
    if (!open) return

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }

    function closeOnOutsidePointer(event: PointerEvent) {
      const target = event.target
      if (target instanceof Node) {
        if (ref.current?.contains(target)) return
        if (extraRefs.some((extraRef) => extraRef.current?.contains(target))) return
      }

      onClose()
    }

    window.addEventListener("keydown", closeOnEscape)
    window.addEventListener("pointerdown", closeOnOutsidePointer)
    return () => {
      window.removeEventListener("keydown", closeOnEscape)
      window.removeEventListener("pointerdown", closeOnOutsidePointer)
    }
  }, [open, onClose, extraRefs])

  return ref
}

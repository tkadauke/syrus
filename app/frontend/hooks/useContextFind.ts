import { useEffect } from "react"

export function isContextFindEditableTarget(target: EventTarget | null) {
  if (!(target instanceof Element)) return false

  return Boolean(target.closest("input, textarea, select, [contenteditable]"))
}

export function useContextFindShortcut({ enabled = true, onOpen }: { enabled?: boolean; onOpen: () => boolean | void }) {
  useEffect(() => {
    if (!enabled) return

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() !== "f") return
      if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return
      if (isContextFindEditableTarget(event.target)) return

      const handled = onOpen()
      if (handled === false) return

      event.preventDefault()
      event.stopPropagation()
    }

    window.addEventListener("keydown", handleKeyDown)
    return () => window.removeEventListener("keydown", handleKeyDown)
  }, [enabled, onOpen])
}

import { useEffect, useRef, useState } from "react"
import type { KeyboardEvent } from "react"

// Shared arrow-key/Enter navigation for combobox-style dropdown lists
// (filter search menus, typeahead value pickers). highlightedIndex -1
// means "text field is focused, no item highlighted" -- the default
// state, matching these dropdowns' autofocus-the-input behavior. Arrow
// keys cycle through itemCount items and wrap back to -1 at either end,
// standard combobox behavior. Positions are tracked as highlightedIndex
// + 1 (0 = text field, 1..itemCount = items) so wrapping is a plain
// modulo instead of special-cased boundary checks.
export function useListNavigation({ itemCount, onSelect, resetKey }: { itemCount: number; onSelect: (index: number) => void; resetKey?: unknown }) {
  const [highlightedIndex, setHighlightedIndex] = useState(-1)
  const itemRefs = useRef<Array<HTMLElement | null>>([])

  useEffect(() => {
    setHighlightedIndex(-1)
  }, [resetKey])

  function registerItem(index: number) {
    return (element: HTMLElement | null) => {
      itemRefs.current[index] = element
    }
  }

  function moveHighlight(nextIndex: number) {
    setHighlightedIndex(nextIndex)
    if (nextIndex >= 0) itemRefs.current[nextIndex]?.scrollIntoView({ block: "nearest" })
  }

  function handleKeyDown(event: KeyboardEvent<HTMLElement>) {
    if (itemCount === 0 && (event.key === "ArrowDown" || event.key === "ArrowUp")) return

    if (event.key === "ArrowDown") {
      event.preventDefault()
      const position = (highlightedIndex + 1 + 1) % (itemCount + 1)
      moveHighlight(position - 1)
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      const position = (highlightedIndex + 1 - 1 + (itemCount + 1)) % (itemCount + 1)
      moveHighlight(position - 1)
    } else if (event.key === "Enter") {
      if (highlightedIndex >= 0) onSelect(highlightedIndex)
    }
  }

  return { highlightedIndex, setHighlightedIndex, handleKeyDown, registerItem }
}

import { type UIEvent, useEffect, useRef, useState } from "react"

const BUFFER_ROWS = 3
const DEFAULT_VIEWPORT_HEIGHT = 480

// Row virtualization shared by the macro (worker lanes) and micro (Step
// lanes) chart views: only rows within the scrolled-into-view range (plus a
// small buffer) render their content.
export function useVirtualizedRows(itemCount: number, rowHeight: number) {
  const scrollRef = useRef<HTMLDivElement | null>(null)
  const [scrollTop, setScrollTop] = useState(0)
  const [viewportHeight, setViewportHeight] = useState(DEFAULT_VIEWPORT_HEIGHT)

  useEffect(() => {
    const el = scrollRef.current
    if (!el) return

    const measure = () => {
      if (el.clientHeight > 0) setViewportHeight(el.clientHeight)
    }
    measure()

    if (typeof ResizeObserver === "undefined") return undefined
    const observer = new ResizeObserver(measure)
    observer.observe(el)
    return () => observer.disconnect()
  }, [])

  const startIndex = Math.max(0, Math.floor(scrollTop / rowHeight) - BUFFER_ROWS)
  const endIndex = Math.min(itemCount, Math.ceil((scrollTop + viewportHeight) / rowHeight) + BUFFER_ROWS)
  const totalHeight = itemCount * rowHeight

  function onScroll(event: UIEvent<HTMLDivElement>) {
    setScrollTop(event.currentTarget.scrollTop)
  }

  return { scrollRef, startIndex, endIndex, totalHeight, onScroll }
}

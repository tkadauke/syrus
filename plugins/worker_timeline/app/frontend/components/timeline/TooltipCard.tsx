import { useLayoutEffect, useRef, useState, type ReactNode } from "react"

const CURSOR_OFFSET = 12
const EDGE_MARGIN = 8

// Positioning/styling wrapper for hover tooltips, shared by the macro
// (span) and micro (Run/Step) chart views -- each composes its own content.
export function TooltipCard({ x, y, children }: { x: number; y: number; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState({ left: x + CURSOR_OFFSET, top: y + CURSOR_OFFSET })

  // Runs before the browser paints, so the initial unclamped guess above is
  // never actually shown -- no flip/clamp jank at the viewport edge.
  useLayoutEffect(() => {
    const rect = ref.current?.getBoundingClientRect()

    setPosition(clampToViewport(
      { x, y },
      { width: rect?.width ?? 0, height: rect?.height ?? 0 },
      { width: window.innerWidth, height: window.innerHeight }
    ))
  }, [ x, y, children ])

  return (
    <div
      className="pointer-events-none fixed z-50 max-w-xs rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-2 text-xs text-gray-800 dark:text-gray-100 shadow-lg"
      ref={ref}
      role="tooltip"
      style={{ left: position.left, top: position.top }}
    >
      {children}
    </div>
  )
}

// Exported for direct unit coverage of the flip/clamp math without needing
// to mock layout in a DOM test for every case.
export function clampToViewport(
  cursor: { x: number; y: number },
  size: { width: number; height: number },
  viewport: { width: number; height: number }
): { left: number; top: number } {
  const left = flipOrClamp(cursor.x, size.width, viewport.width)
  const top = flipOrClamp(cursor.y, size.height, viewport.height)
  return { left, top }
}

function flipOrClamp(cursorPos: number, size: number, viewportSize: number): number {
  const preferred = cursorPos + CURSOR_OFFSET
  const flipped = cursorPos - CURSOR_OFFSET - size
  const position = preferred + size > viewportSize ? flipped : preferred
  const maxPosition = Math.max(EDGE_MARGIN, viewportSize - size - EDGE_MARGIN)

  return Math.min(Math.max(position, EDGE_MARGIN), maxPosition)
}

import type { ReactNode } from "react"

// Positioning/styling wrapper for hover tooltips, shared by the macro
// (span) and micro (Run/Step) chart views -- each composes its own content.
export function TooltipCard({ x, y, children }: { x: number; y: number; children: ReactNode }) {
  return (
    <div
      className="pointer-events-none fixed z-50 max-w-xs rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-2 text-xs text-gray-800 dark:text-gray-100 shadow-lg"
      role="tooltip"
      style={{ left: x + 12, top: y + 12 }}
    >
      {children}
    </div>
  )
}

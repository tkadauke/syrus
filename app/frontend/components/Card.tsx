import type { HTMLAttributes } from "react"

export type CardVariant = "base" | "preview"

export interface CardProps extends HTMLAttributes<HTMLDivElement> {
  variant?: CardVariant
  compact?: boolean
}

const BASE_CLASSES = "rounded border border-border bg-surface p-4"
const PREVIEW_CLASSES = "w-80 rounded-lg border border-border bg-surface p-4 shadow-lg"
const PREVIEW_COMPACT_CLASSES = "w-40 min-h-14 rounded-lg border border-border bg-surface p-3 shadow-lg"

// Shared card primitive: the plain "base" look used by CoverageCard/
// SccacheCard-style sections, and the "preview" hover/popover look used
// by JobPreviewCard/EpicPreviewCard/PrPreviewCard, both token-styled so
// light/dark stay in sync without each caller hand-rolling the same
// border/rounded/padding/shadow class string.
export function Card({ variant = "base", compact = false, className = "", ...props }: CardProps) {
  const variantClasses = variant === "preview" ? (compact ? PREVIEW_COMPACT_CLASSES : PREVIEW_CLASSES) : BASE_CLASSES

  return <div className={`${variantClasses} ${className}`.trim()} {...props} />
}

// Shared loading-placeholder bar, replacing the `animate-pulse` +
// `bg-gray-200 dark:bg-gray-700` div duplicated across JobPreviewSkeleton,
// EpicPreviewSkeleton, and PrPreviewSkeleton. Callers size/shape it with
// `className` (e.g. `h-4 w-3/4`, `h-4 w-16 rounded-full`).
export function Skeleton({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`animate-pulse rounded bg-border ${className}`.trim()} {...props} />
}

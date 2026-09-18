import type { HTMLAttributes } from "react"
import { classes } from "./classes"

export type SurfaceVariant = "panel" | "raised" | "subtle" | "inset" | "danger" | "warning" | "success"
export type SurfacePadding = "none" | "sm" | "md" | "lg"

export interface SurfaceProps extends HTMLAttributes<HTMLDivElement> {
  variant?: SurfaceVariant
  padding?: SurfacePadding
}

export const SURFACE_VARIANT_CLASSES: Record<SurfaceVariant, string> = {
  panel: "border-border bg-surface text-text-primary",
  raised: "border-border bg-surface text-text-primary shadow-[var(--shadow-panel)]",
  subtle: "border-transparent bg-surface-subtle text-text-primary",
  inset: "border-border bg-surface-inset text-text-primary",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  success: "border-success-border bg-success-surface text-success-text"
}

export const SURFACE_PADDING_CLASSES: Record<SurfacePadding, string> = {
  none: "p-0",
  sm: "p-[var(--space-section-compact)]",
  md: "p-[var(--space-section)]",
  // "lg" stays a literal p-6: the spacing token group only models
  // page/section rhythm (--space-page-*, --space-section*), not a third
  // "large" step, so there's no token for this variant to consume yet.
  lg: "p-6"
}

// Clips a panel's descendants to its own rounded corners without using
// `overflow`, which becomes the nearest scroll container for any
// `position: sticky` descendant the moment it's non-visible -- even when the
// ancestor itself never scrolls (e.g. a panel wrapping a diff viewer whose
// sticky file headers pin against the page, not the panel). `clip-path`
// performs the same corner clip while leaving sticky positioning alone.
export const SURFACE_CLIP_ROUNDED_CLASS = "[clip-path:inset(0_round_var(--radius-panel))]"

export function surfaceClasses(variant: SurfaceVariant = "panel", padding: SurfacePadding = "md", className = "") {
  return classes(
    "rounded-[var(--radius-panel)] border border-[length:var(--border-width)]",
    SURFACE_VARIANT_CLASSES[variant],
    SURFACE_PADDING_CLASSES[padding],
    className
  )
}

export function Surface({ variant = "panel", padding = "md", className = "", ...props }: SurfaceProps) {
  return <div className={surfaceClasses(variant, padding, className)} {...props} />
}

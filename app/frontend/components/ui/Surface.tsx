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
  lg: "p-6"
}

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

import type { HTMLAttributes } from "react"
import { classes } from "./classes"

export type SemanticTone = "neutral" | "info" | "warning" | "danger" | "success"

export interface PillProps extends HTMLAttributes<HTMLSpanElement> {
  active?: boolean
  tone?: SemanticTone
}

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: SemanticTone
}

export const TONE_CHIP_CLASSES: Record<SemanticTone, string> = {
  neutral: "bg-neutral-surface text-neutral-text ring-neutral-border",
  info: "bg-info-surface text-info-text ring-info-border",
  warning: "bg-warning-surface text-warning-text ring-warning-border",
  danger: "bg-danger-surface text-danger-text ring-danger-border",
  success: "bg-success-surface text-success-text ring-success-border"
}

export function pillClasses(tone: SemanticTone = "neutral", className = "") {
  return classes("inline-flex items-center gap-1.5 whitespace-nowrap rounded-[var(--radius-pill)] px-2 py-0.5 text-xs font-medium ring-1", TONE_CHIP_CLASSES[tone], className)
}

export function badgeClasses(tone: SemanticTone = "neutral", className = "") {
  return classes("inline-flex items-center whitespace-nowrap rounded-[var(--radius-control)] px-1.5 py-0.5 text-2xs font-medium uppercase leading-4 tracking-wide ring-1", TONE_CHIP_CLASSES[tone], className)
}

export function Pill({ active = false, children, className = "", tone = "neutral", ...props }: PillProps) {
  return (
    <span className={pillClasses(tone, className)} {...props}>
      {active ? <span aria-hidden="true" className="h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-info/30 border-t-info" data-running-spinner="true" /> : null}
      <span>{children}</span>
    </span>
  )
}

export function Badge({ className = "", tone = "neutral", ...props }: BadgeProps) {
  return <span className={badgeClasses(tone, className)} {...props} />
}

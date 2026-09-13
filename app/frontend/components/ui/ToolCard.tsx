import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import type { SemanticTone } from "./Pill"

export type ToolCardState = "pending" | "running" | "succeeded" | "failed" | "neutral"

export interface ToolCardRootProps extends HTMLAttributes<HTMLDivElement> {
  state?: ToolCardState
}

export interface ToolCardHeaderProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  icon?: ReactNode
  meta?: ReactNode
  title: ReactNode
}

export interface ToolCardSectionProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  title?: ReactNode
}

export interface ToolCardBadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: SemanticTone
}

const STATE_CLASSES: Record<ToolCardState, string> = {
  pending: "border-info-border bg-info-surface",
  running: "border-info-border bg-info-surface",
  succeeded: "border-success-border bg-success-surface",
  failed: "border-danger-border bg-danger-surface",
  neutral: "border-border bg-surface-subtle"
}

const BADGE_CLASSES: Record<SemanticTone, string> = {
  neutral: "bg-neutral-surface text-neutral-text ring-neutral-border",
  info: "bg-info-surface text-info-text ring-info-border",
  warning: "bg-warning-surface text-warning-text ring-warning-border",
  danger: "bg-danger-surface text-danger-text ring-danger-border",
  success: "bg-success-surface text-success-text ring-success-border"
}

function Root({ className = "", state = "neutral", ...props }: ToolCardRootProps) {
  return (
    <div
      className={classes("mt-1 space-y-2 rounded-[var(--radius-panel)] border p-3 text-xs text-text-primary", STATE_CLASSES[state], className)}
      data-tool-card-state={state}
      {...props}
    />
  )
}

function Header({ className = "", icon, meta, title, ...props }: ToolCardHeaderProps) {
  return (
    <div className={classes("flex min-w-0 items-start justify-between gap-3", className)} {...props}>
      <div className="flex min-w-0 items-center gap-2">
        {icon ? <span className="shrink-0 text-text-muted" aria-hidden="true">{icon}</span> : null}
        <div className="min-w-0 truncate text-sm font-semibold text-text-primary">{title}</div>
      </div>
      {meta ? <div className="shrink-0 text-xs text-text-muted">{meta}</div> : null}
    </div>
  )
}

function Body({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("min-w-0 text-xs text-text-secondary", className)} {...props} />
}

function Section({ children, className = "", title, ...props }: ToolCardSectionProps) {
  return (
    <section className={classes("min-w-0 space-y-1", className)} {...props}>
      {title ? <div className="text-2xs font-semibold uppercase tracking-wide text-text-muted">{title}</div> : null}
      {children}
    </section>
  )
}

function Badge({ className = "", tone = "neutral", ...props }: ToolCardBadgeProps) {
  return <span className={classes("inline-flex items-center rounded-[var(--radius-pill)] px-2 py-0.5 text-2xs font-medium ring-1", BADGE_CLASSES[tone], className)} {...props} />
}

export const ToolCard = {
  Root,
  Header,
  Body,
  Section,
  Badge
}

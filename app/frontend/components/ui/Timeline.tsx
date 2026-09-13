import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import type { SemanticTone } from "./Pill"

export interface TimelineRootProps extends HTMLAttributes<HTMLDivElement> {
  density?: "default" | "compact"
}

export interface TimelineItemProps extends HTMLAttributes<HTMLDivElement> {
  marker?: ReactNode
  markerLabel?: string
  tone?: SemanticTone
}

export interface ActivityRowRootProps extends HTMLAttributes<HTMLDivElement> {
  actions?: ReactNode
}

const MARKER_CLASSES: Record<SemanticTone, string> = {
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text",
  info: "border-info-border bg-info-surface text-info-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  success: "border-success-border bg-success-surface text-success-text"
}

function Root({ className = "", density = "default", ...props }: TimelineRootProps) {
  return (
    <div
      className={classes("relative space-y-0", density === "compact" ? "[--timeline-gap:0.75rem]" : "[--timeline-gap:1rem]", className)}
      data-timeline-density={density}
      {...props}
    />
  )
}

function Item({ children, className = "", marker, markerLabel, tone = "neutral", ...props }: TimelineItemProps) {
  return (
    <div className={classes("relative grid grid-cols-[1.5rem_minmax(0,1fr)] gap-3 pb-[var(--timeline-gap)] last:pb-0 last:[&_[data-timeline-line]]:hidden", className)} data-timeline-tone={tone} {...props}>
      <div className="relative flex justify-center">
        <span aria-hidden="true" className="absolute bottom-0 top-6 w-px bg-border" data-timeline-line="true" />
        <span
          aria-label={markerLabel}
          className={classes("z-10 flex h-6 w-6 shrink-0 items-center justify-center rounded-[var(--radius-pill)] border text-2xs font-semibold", MARKER_CLASSES[tone])}
          role={markerLabel ? "img" : undefined}
        >
          {marker ?? <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-current" />}
        </span>
      </div>
      <div className="min-w-0">{children}</div>
    </div>
  )
}

function ActivityRoot({ actions, children, className = "", ...props }: ActivityRowRootProps) {
  return (
    <div className={classes("min-w-0 rounded-[var(--radius-control)] px-0 py-0.5", className)} {...props}>
      <div className="flex min-w-0 items-start justify-between gap-3">
        <div className="min-w-0 flex-1">{children}</div>
        {actions ? <div className="shrink-0">{actions}</div> : null}
      </div>
    </div>
  )
}

function ActivityTitle({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("truncate text-sm font-medium text-text-primary", className)} {...props} />
}

function ActivityMeta({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("mt-0.5 flex min-w-0 flex-wrap items-center gap-2 text-xs text-text-muted", className)} {...props} />
}

function ActivityBody({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("mt-1 text-sm text-text-secondary", className)} {...props} />
}

export const Timeline = {
  Root,
  Item
}

export const ActivityRow = {
  Root: ActivityRoot,
  Title: ActivityTitle,
  Meta: ActivityMeta,
  Body: ActivityBody
}

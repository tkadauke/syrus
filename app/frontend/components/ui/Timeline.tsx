import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Text } from "./Text"

export type TimelineTone = "neutral" | "info" | "success" | "warning" | "danger"

export interface TimelineProps extends HTMLAttributes<HTMLOListElement> {
  density?: "normal" | "compact"
}

export interface ActivityRowProps extends Omit<HTMLAttributes<HTMLLIElement>, "title"> {
  actions?: ReactNode
  description?: ReactNode
  eyebrow?: ReactNode
  meta?: ReactNode
  title: ReactNode
  tone?: TimelineTone
}

const TIMELINE_TONE_CLASSES: Record<TimelineTone, string> = {
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text",
  info: "border-info-border bg-info-surface text-info-text",
  success: "border-success-border bg-success-surface text-success-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text"
}

export function Timeline({ children, className = "", density = "normal", ...props }: TimelineProps) {
  return (
    <ol
      className={classes("min-w-0 divide-y divide-border rounded-[var(--radius-panel)] border border-border bg-surface", density === "compact" ? "text-xs" : "text-sm", className)}
      data-timeline="true"
      {...props}
    >
      {children}
    </ol>
  )
}

export function ActivityRow({
  actions,
  className = "",
  description,
  eyebrow,
  meta,
  title,
  tone = "neutral",
  ...props
}: ActivityRowProps) {
  return (
    <li className={classes("flex min-w-0 gap-3 px-3 py-3", className)} data-activity-row="true" {...props}>
      <span
        aria-hidden="true"
        className={classes("mt-1 h-2.5 w-2.5 shrink-0 rounded-full border border-[length:var(--border-width)]", TIMELINE_TONE_CLASSES[tone])}
        data-activity-row-marker="true"
      />
      <div className="min-w-0 flex-1">
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            {eyebrow ? <Text as="div" className="truncate" muted variant="label">{eyebrow}</Text> : null}
            <Text as="div" className="truncate" variant="heading-sm">{title}</Text>
          </div>
          {meta ? <div className="shrink-0 text-right"><Text as="div" muted variant="caption">{meta}</Text></div> : null}
        </div>
        {description ? <Text as="div" className="mt-1 min-w-0 break-words" muted variant="caption">{description}</Text> : null}
        {actions ? <div className="mt-2 flex flex-wrap gap-2">{actions}</div> : null}
      </div>
    </li>
  )
}

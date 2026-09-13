import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import type { SemanticTone } from "./Pill"

export interface TimelineRootProps extends HTMLAttributes<HTMLOListElement> {
  density?: "compact" | "comfortable"
}

export interface ActivityRowProps extends Omit<HTMLAttributes<HTMLLIElement>, "title"> {
  actions?: ReactNode
  details?: ReactNode
  icon?: ReactNode
  meta?: ReactNode
  timestamp?: ReactNode
  title: ReactNode
  tone?: SemanticTone
}

const TONE_DOT_CLASSES: Record<SemanticTone, string> = {
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text",
  info: "border-info-border bg-info-surface text-info-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  success: "border-success-border bg-success-surface text-success-text"
}

const DENSITY_CLASSES: Record<NonNullable<TimelineRootProps["density"]>, string> = {
  compact: "space-y-2",
  comfortable: "space-y-3"
}

function Root({ className = "", density = "compact", ...props }: TimelineRootProps) {
  return <ol className={classes("relative", DENSITY_CLASSES[density], className)} {...props} />
}

export function ActivityRow({
  actions,
  className = "",
  details,
  icon,
  meta,
  timestamp,
  title,
  tone = "neutral",
  ...props
}: ActivityRowProps) {
  return (
    <li className={classes("relative grid grid-cols-[1.5rem,minmax(0,1fr)] gap-2", className)} {...props}>
      <div aria-hidden="true" className="relative flex justify-center">
        <span className="absolute bottom-[-0.75rem] top-6 w-px bg-border" data-timeline-connector="true" />
        <span className={classes("relative z-10 flex h-5 w-5 items-center justify-center rounded-full border text-[0.625rem]", TONE_DOT_CLASSES[tone])}>
          {icon}
        </span>
      </div>
      <div className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-2">
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="truncate text-sm font-medium leading-5 text-text-primary">{title}</div>
            {meta ? <div className="mt-0.5 truncate text-xs leading-4 text-text-muted">{meta}</div> : null}
          </div>
          {timestamp ? <div className="shrink-0 whitespace-nowrap text-2xs font-medium uppercase leading-4 tracking-wide text-text-subtle">{timestamp}</div> : null}
        </div>
        {details ? <div className="mt-2 min-w-0 text-xs leading-4 text-text-muted">{details}</div> : null}
        {actions ? <div className="mt-2 flex flex-wrap items-center gap-2">{actions}</div> : null}
      </div>
    </li>
  )
}

export const Timeline = { Root, ActivityRow }

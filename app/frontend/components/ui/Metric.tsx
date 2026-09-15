import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Surface } from "./Surface"
import type { SemanticTone } from "./Pill"

export interface MetricGroupProps extends HTMLAttributes<HTMLDivElement> {
  columns?: "auto" | 2 | 3 | 4
}

export interface MetricCardProps extends HTMLAttributes<HTMLDivElement> {
  description?: ReactNode
  label: ReactNode
  meta?: ReactNode
  tone?: SemanticTone
  value: ReactNode
}

const GROUP_COLUMN_CLASSES: Record<NonNullable<MetricGroupProps["columns"]>, string> = {
  auto: "grid-cols-[repeat(auto-fit,minmax(10rem,1fr))]",
  2: "sm:grid-cols-2",
  3: "sm:grid-cols-2 lg:grid-cols-3",
  4: "sm:grid-cols-2 xl:grid-cols-4"
}

const VALUE_TONE_CLASSES: Record<SemanticTone, string> = {
  neutral: "text-text-primary",
  info: "text-info-text",
  warning: "text-warning-text",
  danger: "text-danger-text",
  success: "text-success-text"
}

function Group({ className = "", columns = "auto", ...props }: MetricGroupProps) {
  return <div className={classes("grid gap-3", GROUP_COLUMN_CLASSES[columns], className)} {...props} />
}

function Card({ className = "", description, label, meta, tone = "neutral", value, ...props }: MetricCardProps) {
  return (
    <Surface className={classes("min-w-0", className)} padding="sm" variant="panel" {...props}>
      <div className="min-w-0">
        <div className="truncate text-xs font-medium uppercase leading-4 tracking-wide text-text-muted">{label}</div>
        <div className={classes("mt-1 truncate font-mono text-2xl font-semibold leading-8", VALUE_TONE_CLASSES[tone])}>{value}</div>
        {description ? <div className="mt-1 text-xs leading-4 text-text-muted">{description}</div> : null}
        {meta ? <div className="mt-2 text-2xs font-medium uppercase leading-4 tracking-wide text-text-subtle">{meta}</div> : null}
      </div>
    </Surface>
  )
}

export const Metric = { Group, Card }
export const Stat = Metric

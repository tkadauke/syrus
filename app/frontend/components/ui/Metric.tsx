import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import type { SemanticTone } from "./Pill"

export type MetricDensity = "default" | "compact"

export interface MetricGroupProps extends HTMLAttributes<HTMLDivElement> {
  density?: MetricDensity
}

export interface MetricCardProps extends HTMLAttributes<HTMLDivElement> {
  context?: ReactNode
  label: ReactNode
  tone?: SemanticTone
  trend?: ReactNode
  value: ReactNode
}

export interface StatProps extends HTMLAttributes<HTMLDivElement> {
  label: ReactNode
  value: ReactNode
}

export interface StatGroupProps extends HTMLAttributes<HTMLDListElement> {
  density?: MetricDensity
}

const GROUP_DENSITY_CLASSES: Record<MetricDensity, string> = {
  default: "grid gap-3 sm:grid-cols-2 lg:grid-cols-4",
  compact: "grid gap-2 sm:grid-cols-2 lg:grid-cols-4"
}

const TONE_CLASSES: Record<SemanticTone, string> = {
  neutral: "border-border bg-surface text-text-primary",
  info: "border-info-border bg-info-surface text-info-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  success: "border-success-border bg-success-surface text-success-text"
}

function Group({ className = "", density = "default", ...props }: MetricGroupProps) {
  return <div className={classes(GROUP_DENSITY_CLASSES[density], className)} {...props} />
}

function Card({ className = "", context, label, tone = "neutral", trend, value, ...props }: MetricCardProps) {
  return (
    <div className={classes("min-w-0 rounded-[var(--radius-panel)] border p-3", TONE_CLASSES[tone], className)} data-metric-tone={tone} {...props}>
      <div className="truncate text-xs font-medium uppercase leading-4 tracking-wide opacity-80">{label}</div>
      <div className="mt-1 truncate text-2xl font-semibold leading-8 text-text-primary">{value}</div>
      {context || trend ? (
        <div className="mt-1 flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 text-xs text-text-muted">
          {context ? <span className="min-w-0 truncate">{context}</span> : null}
          {trend ? <span className="font-medium">{trend}</span> : null}
        </div>
      ) : null}
    </div>
  )
}

function StatGroup({ className = "", density = "default", ...props }: StatGroupProps) {
  return <dl className={classes(GROUP_DENSITY_CLASSES[density], className)} {...props} />
}

function StatItem({ className = "", label, value, ...props }: StatProps) {
  return (
    <div className={classes("min-w-0", className)} {...props}>
      <dt className="truncate text-xs font-medium uppercase leading-4 tracking-wide text-text-muted">{label}</dt>
      <dd className="truncate text-sm font-medium text-text-primary">{value}</dd>
    </div>
  )
}

export const Metric = {
  Group,
  Card
}

export const Stat = {
  Group: StatGroup,
  Item: StatItem
}

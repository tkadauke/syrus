import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Text } from "./Text"

export type MetricTone = "default" | "neutral" | "info" | "success" | "warning" | "danger"
export type MetricDensity = "normal" | "compact"

export interface MetricGroupProps extends HTMLAttributes<HTMLDivElement> {
  columns?: 2 | 3 | 4
}

export interface MetricProps extends HTMLAttributes<HTMLDivElement> {
  detail?: ReactNode
  density?: MetricDensity
  label: ReactNode
  tone?: MetricTone
  value: ReactNode
}

const METRIC_GROUP_COLUMNS: Record<NonNullable<MetricGroupProps["columns"]>, string> = {
  2: "sm:grid-cols-2",
  3: "sm:grid-cols-2 lg:grid-cols-3",
  4: "sm:grid-cols-2 xl:grid-cols-4"
}

const METRIC_TONE_CLASSES: Record<MetricTone, string> = {
  default: "border-border bg-surface text-text-primary",
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text",
  info: "border-info-border bg-info-surface text-info-text",
  success: "border-success-border bg-success-surface text-success-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text"
}

export function MetricGroup({ children, className = "", columns = 4, ...props }: MetricGroupProps) {
  return (
    <div
      className={classes("grid min-w-0 grid-cols-1 gap-3", METRIC_GROUP_COLUMNS[columns], className)}
      data-metric-group="true"
      {...props}
    >
      {children}
    </div>
  )
}

export function Metric({
  className = "",
  density = "normal",
  detail,
  label,
  tone = "default",
  value,
  ...props
}: MetricProps) {
  return (
    <div
      className={classes(
        "min-w-0 rounded-[var(--radius-panel)] border border-[length:var(--border-width)]",
        density === "compact" ? "p-3" : "p-4",
        METRIC_TONE_CLASSES[tone],
        className
      )}
      data-metric="true"
      {...props}
    >
      <Text as="div" className="truncate" variant="label">{label}</Text>
      <div className={classes("mt-1 truncate font-semibold", density === "compact" ? "text-xl leading-7" : "text-2xl leading-8")} title={typeof value === "string" ? value : undefined}>
        {value}
      </div>
      {detail ? <Text as="div" className="mt-1 truncate" muted variant="caption">{detail}</Text> : null}
    </div>
  )
}

export const StatGroup = MetricGroup
export const Stat = Metric

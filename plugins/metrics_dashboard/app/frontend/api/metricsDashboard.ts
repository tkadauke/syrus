import { getJson } from "@app/api/client"

export type MetricsSeries = {
  name: string
  /** One entry per bucket in the payload's shared grid; null where nothing was recorded. */
  values: (number | null)[]
}

export type MetricsPanel = {
  key: string
  metric: string
  unit: string
  /** "value" for a gauge, "rate" for the change per bucket of a counter. */
  mode: "value" | "rate" | string
  series: MetricsSeries[]
}

export type MetricsDashboardPayload = {
  window: string
  windows: string[]
  /** ISO timestamps. Shared by every panel, which is what makes one crosshair meaningful. */
  buckets: string[]
  bucket_seconds: number
  recording: boolean
  last_recorded_at: string | null
  panels: MetricsPanel[]
}

export function fetchMetricsDashboard(window: string) {
  return getJson<MetricsDashboardPayload>(`/api/v1/app/metrics_dashboard?window=${encodeURIComponent(window)}`)
}

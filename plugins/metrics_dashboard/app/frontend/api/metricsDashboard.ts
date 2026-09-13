import { getJson } from "@app/api/client"

export type MetricsSeries = {
  name: string
  points: [string, number][]
}

export type MetricsPanel = {
  key: string
  metric: string
  unit: string
  aggregate: string
  series: MetricsSeries[]
}

export type MetricsDashboardPayload = {
  window: string
  windows: string[]
  recording: boolean
  last_recorded_at: string | null
  panels: MetricsPanel[]
}

export function fetchMetricsDashboard(window: string) {
  return getJson<MetricsDashboardPayload>(`/api/v1/app/metrics_dashboard?window=${encodeURIComponent(window)}`)
}

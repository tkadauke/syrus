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
  /** Which tab this panel belongs in. "other" is the fallback for a panel with no real category, or a plugin tab's id. */
  category: string
  /**
   * Set only for a plugin-contributed panel: its chart title as a literal
   * string, since it cannot resolve against this plugin's own `panels.<key>`
   * i18n namespace. A core panel omits this and keeps translating by key.
   */
  label?: string
  series: MetricsSeries[]
}

/** One tab contributed by another plugin through metrics_dashboard's hosted "metrics_dashboard:tab" point. */
export type MetricsPluginTab = {
  id: string
  label: string
}

export type MetricsDashboardPayload = {
  window: string
  windows: string[]
  /** ISO timestamps. Shared by every panel, which is what makes one crosshair meaningful. */
  buckets: string[]
  bucket_seconds: number
  recording: boolean
  last_recorded_at: string | null
  /** Canonical core tab display order. Includes "other" only when some panel actually fell back to it. */
  categories: string[]
  /** One entry per currently enabled plugin that contributes a tab. */
  plugin_tabs: MetricsPluginTab[]
  panels: MetricsPanel[]
}

export function fetchMetricsDashboard(window: string) {
  return getJson<MetricsDashboardPayload>(`/api/v1/app/metrics_dashboard?window=${encodeURIComponent(window)}`)
}

// Shared layout/color constants for the worker-activity-timeline plugin's
// macro (TimelineLanes) and micro (WorkflowWaterfall) chart views.
export const ROW_HEIGHT = 44
export const CHART_WIDTH = 1000

export const STATUS_COLORS: Record<string, string> = {
  queued: "#f59e0b",
  running: "#2563eb",
  succeeded: "#16a34a",
  failed: "#dc2626",
  cancelled: "#6b7280"
}

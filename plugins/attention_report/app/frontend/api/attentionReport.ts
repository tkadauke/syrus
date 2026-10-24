import { getJson } from "@app/api/client"

export type AttentionFigure = { count?: number; value_ms?: number; sample_count: number; estimate: boolean; job_ids?: number[] }
export type AttentionBucket = { figures: Record<string, AttentionFigure>; estimate: boolean }
export type AttentionRuleBucket = { rules: Record<string, AttentionFigure>; estimate: boolean }
export type AttentionPercentile = { status: "available" | "not_enough_data"; value_ms?: number; sample_count: number }
export type AttentionPageStatistic = {
  sample_count: number
  p50_active_ms: AttentionPercentile
  p90_active_ms: AttentionPercentile
  enough_data: boolean
  estimate: boolean
}

export type AttentionReportPayload = {
  window: { days: number; from: string; to: string }
  attention: { deciding: AttentionBucket; judging: AttentionBucket; wasted: AttentionRuleBucket }
  page_time: { telemetry_state: "on" | "off"; by_page_type: Record<string, AttentionPageStatistic> }
  machine_time: { agent_runtime: AttentionFigure; queue_wait: AttentionFigure; included_in_attention: false }
  metadata: { attention_totals_exclude_machine_time: true; current_user_only: true }
}

export function fetchAttentionReport(windowDays: 7 | 30) {
  return getJson<AttentionReportPayload>(`/api/v1/app/insights/attention?window_days=${windowDays}`)
}

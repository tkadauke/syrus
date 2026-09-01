export type ProviderAvailability = {
  provider: string
  label: string
  model: string | null
  state: "available" | "exhausted" | "open" | "rate_limited" | "auth_error" | string
  open: boolean
  usage_exhausted: boolean
  retry_after: string | null
  reason: string | null
  message: string
  pause_threshold_percent?: number
  pause_enabled?: boolean
  override_active?: boolean
  usage?: {
    status?: string | null
    observed_at?: string | null
    remaining_percent?: number | null
    evidence?: ProviderAvailabilityEvidence | null
    windows?: {
      five_hour?: ProviderUsageWindow
      weekly?: ProviderUsageWindow
    }
  } | null
  evidence?: {
    current?: ProviderAvailabilityEvidence | null
    latest_positive?: ProviderAvailabilityEvidence | null
    latest_negative?: ProviderAvailabilityEvidence | null
  } | null
} | null

export type ProviderUsageWindow = {
  label: string
  remaining_percent?: number | null
  used_percent?: number | null
  reset_at?: string | null
}

export type ProviderAvailabilityEvidence = {
  status: string
  source: string
  observed_at?: string | null
  provider?: string | null
  account_id?: string | null
  model?: string | null
  run_id?: number | null
  chat_session_id?: number | null
  chat_message_id?: number | null
  http_status?: number | null
  details?: Record<string, unknown> | null
}

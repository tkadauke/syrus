import { getJson } from "./client"

export type SpendingBreakdownRow = {
  id: number
  label: string
  path: string
  jobs_count: number
  total_usd: number
  average_job_usd: number
  display_number?: string
  last_30_days_usd?: number
}

export type SpendingTriggerRow = {
  trigger_kind: string
  jobs_count: number
  runs_count: number
  total_usd: number
  average_usd: number
}

export type SpendingPayload = {
  scope: {
    admin: boolean
    user_id: number
    label: string
  }
  filters: {
    start_date: string
    end_date: string
    default_window_days: number
  }
  totals: {
    week_usd: number
    month_usd: number
    lifetime_usd: number
    workflow_lifetime_usd: number
    chat_lifetime_usd: number
    average_job_30d_usd: number
    average_merged_pr_30d_usd: number
  }
  breakdowns: {
    epics: SpendingBreakdownRow[]
    users: SpendingBreakdownRow[]
    repositories: SpendingBreakdownRow[]
    trigger_kinds: SpendingTriggerRow[]
  }
  top_runs: Array<{
    id: number
    cost_usd: number
    trigger_kind: string
    agent_provider: string
    created_at: string
    job: {
      id: number
      title: string
      path: string
    }
    repository: {
      id: number
      slug: string
      path: string
    }
    epic: {
      id: number
      display_number: string
      title: string
      path: string
    } | null
  }>
  trend: Array<{
    date: string
    total_usd: number
  }>
}

export function fetchSpending(search = "") {
  return getJson<SpendingPayload>(`/api/v1/app/insights/spending${search}`)
}

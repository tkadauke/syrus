import { getJson } from "@app/api/client"

export type GithubApiUsageTotals = {
  requests: number
  rate_limited: number
}

export type GithubApiUsageOperationRow = {
  auth_source: string
  operation: string
  resource: string
  requests: number
  rate_limited: number
  min_remaining: number | null
  last_limit?: number | null
  last_seen_at: string | null
}

export type GithubApiUsageRepositoryRow = {
  auth_source: string
  repo_slug: string
  requests: number
  rate_limited: number
  min_remaining: number | null
  last_seen_at: string | null
}

export type GithubApiUsagePayload = {
  hours: number
  generated_at: string
  totals: GithubApiUsageTotals
  by_operation: GithubApiUsageOperationRow[]
  by_repository: GithubApiUsageRepositoryRow[]
  recent_rate_limits: (GithubApiUsageOperationRow & { repo_slug?: string | null })[]
}

export function fetchGithubApiUsage(hours: number) {
  return getJson<GithubApiUsagePayload>(`/api/v1/app/admin/github_api_usage?hours=${encodeURIComponent(String(hours))}`)
}

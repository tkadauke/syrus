import { getJson } from "@app/api/client"
import type { FilterSchemaField, FilterTree } from "@app/components/FilterBar"

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
  filter: FilterTree
  filter_schema: FilterSchemaField[]
  generated_at: string
  totals: GithubApiUsageTotals
  by_operation: GithubApiUsageOperationRow[]
  by_repository: GithubApiUsageRepositoryRow[]
  recent_rate_limits: (GithubApiUsageOperationRow & { repo_slug?: string | null })[]
}

export function fetchGithubApiUsage(search = "") {
  return getJson<GithubApiUsagePayload>(`/api/v1/app/admin/github_api_usage${search}`)
}

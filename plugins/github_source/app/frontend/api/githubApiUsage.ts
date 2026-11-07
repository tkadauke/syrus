import { getJson } from "@app/api/client"
import type { FilterSchemaField, FilterTree } from "@app/components/FilterBar"

export type GithubApiUsageTotals = {
  requests: number
  rate_limited: number
}

export type GithubApiUsageOperationRow = {
  auth_source: string
  credential_key?: string | null
  operation: string
  resource: string
  requests: number
  rate_limited: number
  min_remaining: number | null
  last_limit?: number | null
  last_status?: number | null
  last_reset_at?: string | null
  bucket_started_at?: string | null
  last_seen_at: string | null
}

export type GithubApiUsageRepositoryRow = {
  auth_source: string
  credential_key?: string | null
  repo_slug: string
  requests: number
  rate_limited: number
  min_remaining: number | null
  last_limit?: number | null
  last_status?: number | null
  last_reset_at?: string | null
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

let cachedFilterSchema: FilterSchemaField[] | undefined

export function fetchGithubApiUsage(search = "") {
  const params = new URLSearchParams(search)
  if (cachedFilterSchema) params.set("omit_filter_schema", "true")
  const query = params.toString()
  return getJson<GithubApiUsagePayload>(`/api/v1/app/admin/github_api_usage${query ? `?${query}` : ""}`).then((payload) => {
    cachedFilterSchema = payload.filter_schema ?? cachedFilterSchema
    return { ...payload, filter_schema: cachedFilterSchema ?? [] }
  })
}

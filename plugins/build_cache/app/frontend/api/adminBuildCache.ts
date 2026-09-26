import { getJson, postJson } from "@app/api/client"
import type { FilterSchemaField, FilterTree } from "@app/components/FilterBar"

export type BuildCacheObjectSummary = {
  key: string
  size: number
  last_modified: string | null
}

export type BuildCacheStats = {
  object_count: number
  total_size_bytes: number
  oldest_object: BuildCacheObjectSummary | null
  newest_object: BuildCacheObjectSummary | null
  truncated: boolean
}

export type BuildCacheClearRequestScope = "full" | "partial"

export type BuildCacheClearRequest = {
  id: number
  scope: BuildCacheClearRequestScope
  older_than_days: number | null
  reason: string
  state: "pending" | "confirmed" | "cancelled"
  result: { deleted_count: number; bytes_freed: number; truncated: boolean } | null
  result_status: "present" | "empty" | "truncated"
  requested_by: string | null
  created_at: string
  confirmed_at: string | null
  cancelled_at: string | null
  updated_at: string
}

export type AdminBuildCachePayload = {
  configured: boolean
  filter: FilterTree
  filter_schema: FilterSchemaField[]
  stats: BuildCacheStats | null
  stats_error: string | null
  pending_request: BuildCacheClearRequest | null
  recent_requests: BuildCacheClearRequest[]
}

export type AdminBuildCacheStatsPayload = Pick<AdminBuildCachePayload, "configured" | "stats" | "stats_error">

export function fetchAdminBuildCache(search = "", options: { includeStats?: boolean } = {}) {
  const params = new URLSearchParams(search)
  if (options.includeStats) params.set("include_stats", "true")
  const query = params.toString()
  return getJson<AdminBuildCachePayload>(`/api/v1/app/admin/build_cache${query ? `?${query}` : ""}`)
}

export function fetchAdminBuildCacheStats() {
  return getJson<AdminBuildCacheStatsPayload>("/api/v1/app/admin/build_cache/stats")
}

export function createBuildCacheClearRequest(params: { scope: BuildCacheClearRequestScope; older_than_days?: number | null; reason: string }) {
  return postJson<AdminBuildCachePayload>("/api/v1/app/admin/build_cache/clear_requests", {
    admin_build_cache_clear_request: params
  })
}

export function confirmBuildCacheClearRequest(id: number) {
  return postJson<AdminBuildCachePayload>(`/api/v1/app/admin/build_cache/clear_requests/${id}/confirm`)
}

export function cancelBuildCacheClearRequest(id: number) {
  return postJson<AdminBuildCachePayload>(`/api/v1/app/admin/build_cache/clear_requests/${id}/cancel`)
}

export type JobSccacheInfo = {
  workflow_id: number
  run_id: number | null
  step_kind: string | null
  label: string | null
  iteration: number | null
  captured_at: string | null
  summary: {
    hits: number | null
    misses: number | null
    hit_rate: number | null
    cache_size: number | string | null
    max_cache_size: number | string | null
    cache_location: string | null
  }
}

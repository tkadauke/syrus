import { getJson } from "@app/api/client"
import type { RepositoryTab } from "@app/api/repositories"
import type { FilterSchemaField } from "@app/components/FilterBar"

export type RepositoryTestIdentity = {
  id: number
  suite_name: string
  name: string
  file_path: string | null
  fingerprint: string
  last_status: "passed" | "failed" | "skipped" | "error" | null
  last_seen_at: string | null
  last_failed_at: string | null
  last_passed_at: string | null
  last_duration_ms: number | null
  total_count: number
  failed_count: number
  passed_count: number
  failure_rate: number
  avg_duration_ms: number | null
  interesting_reasons: string[]
}

export type RepositoryTestHistoryItem = {
  id: number
  status: "passed" | "failed" | "skipped" | "error"
  duration_ms: number | null
  failure_message: string | null
  created_at: string | null
  grader_name: string
  run: {
    id: number
    slug: string
    path: string
  }
  job: {
    id: number
    slug: string
    title: string
  }
}

export type RepositoryTestDurationPoint = {
  test_case_id: number
  created_at: string | null
  duration_ms: number
  status: "passed" | "failed" | "skipped" | "error"
}

export type RepositoryTestsPayload = {
  repository: {
    id: number
    slug: string
    github_url: string
  }
  tabs: RepositoryTab[]
  filter?: Record<string, unknown> | null
  filter_schema?: FilterSchemaField[]
  tests: RepositoryTestIdentity[]
}

export type RepositoryTestHistoryPagination = {
  page: number
  per_page: number
  total: number
  total_pages: number
}

export type RepositoryTestDetailPayload = {
  repository: RepositoryTestsPayload["repository"]
  tabs: RepositoryTab[]
  test: RepositoryTestIdentity
  history: RepositoryTestHistoryItem[]
  pagination: RepositoryTestHistoryPagination
  duration_points: RepositoryTestDurationPoint[]
}

export function fetchRepositoryTests(repositoryId: string | number, search = "") {
  const params = new URLSearchParams(search)
  const q = params.get("q")
  const suffix = q ? `?q=${encodeURIComponent(q)}` : ""
  return getJson<RepositoryTestsPayload>(`/api/v1/app/repositories/${repositoryId}/tests${suffix}`)
}

export function fetchRepositoryTestDetail(repositoryId: string | number, testId: string | number, page = 1) {
  const params = new URLSearchParams()
  if (page > 1) params.set("page", String(page))
  const suffix = params.toString() ? `?${params}` : ""
  return getJson<RepositoryTestDetailPayload>(`/api/v1/app/repositories/${repositoryId}/tests/${testId}${suffix}`)
}

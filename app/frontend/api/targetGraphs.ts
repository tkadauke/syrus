import { getJson } from "./client"
import type { RepositoryTab } from "./repositories"
import type { FilterSchemaField } from "../components/FilterBar"

export type TargetGraphProject = {
  id: string
  label: string | null
  kind?: string | null
  path?: string | null
  target_count: number
}

export type TargetGraphTarget = {
  label: string
  kind: string
  project_id: string
  source_scope?: string[]
  dependencies: string[]
  executable: boolean
  executable_metadata?: {
    command?: string
    phases?: string[]
    required?: boolean
    timeout_minutes?: number
    metadata?: Record<string, unknown>
  }
  owner_config_path?: string
  selection?: {
    state?: "selected" | "skipped" | "cached"
    reason?: string
    name?: string
    required?: boolean
    target_health_record_id?: number
    checked_at?: string
  }
  health?: TargetGraphHealth | null
}

export type TargetGraphHealth = {
  status: string
  commit_sha?: string
  checked_at?: string
  workflow_id?: number
  step_id?: number
  run_id?: number
  duration_s?: number
  exit_code?: number
}

export type TargetGraphEdge = {
  from: string
  to: string
  kind: string
  in_window: boolean
}

export type TargetGraphPayload = {
  repository: {
    id: number
    slug: string
    default_branch: string
  }
  source: {
    scope: string
    ref: string
  }
  tabs?: RepositoryTab[]
  workflow?: {
    id: number
    slug: string
    job_id: number
    trigger_kind: string
    state: string
  } | null
  projects: TargetGraphProject[]
  targets: TargetGraphTarget[]
  edges: TargetGraphEdge[]
  page: {
    offset: number
    limit: number
    total: number
    next_offset: number | null
  }
  health: {
    scope: string
    targets: Record<string, TargetGraphHealth | null>
    summary: Record<string, number>
  }
  filter?: Record<string, unknown> | null
  filter_schema?: FilterSchemaField[]
  diagnostics?: {
    source?: string
    target_labels?: string[]
    error?: string | null
  } | null
  error?: string | null
}

export type TargetGraphQuery = {
  mode?: "window" | "neighborhood"
  focusLabel?: string
  focusState?: "selected" | "skipped" | "cached" | "failing"
  projectId?: string
  kind?: string
  q?: string
  search?: string
  filter?: string
  workflowId?: string
  direction?: "both" | "dependencies" | "dependents"
  depth?: number
  limit?: number
  offset?: number
}

export function fetchRepositoryTargetGraph(repositoryId: string | number, query: TargetGraphQuery = {}) {
  return getJson<TargetGraphPayload>(`${targetGraphApiPath(`/api/v1/app/repositories/${repositoryId}/target_graph`, query)}`)
}

export function fetchJobTargetGraph(jobId: string | number, query: TargetGraphQuery = {}) {
  return getJson<TargetGraphPayload>(`${targetGraphApiPath(`/api/v1/app/jobs/${jobId}/target_graph`, query)}`)
}

export function fetchWorkflowTargetGraph(workflowId: string | number, query: TargetGraphQuery = {}) {
  return getJson<TargetGraphPayload>(`${targetGraphApiPath(`/api/v1/app/workflows/${workflowId}/target_graph`, query)}`)
}

function targetGraphApiPath(path: string, query: TargetGraphQuery) {
  const params = new URLSearchParams()
  if (query.mode === "neighborhood") params.set("mode", "neighborhood")
  if (query.focusLabel) params.set("focus_label", query.focusLabel)
  if (query.focusState) params.set("focus_state", query.focusState)
  if (query.projectId) params.set("project_id", query.projectId)
  if (query.kind) params.set("kind", query.kind)
  if (query.filter) params.set("q", query.filter)
  else if (query.q) params.set("q", query.q)
  if (query.search) params.set("search", query.search)
  if (query.workflowId) params.set("workflow_id", query.workflowId)
  if (query.direction) params.set("direction", query.direction)
  if (query.depth !== undefined) params.set("depth", String(query.depth))
  if (query.limit !== undefined) params.set("limit", String(query.limit))
  if (query.mode === "window" && query.offset !== undefined) params.set("offset", String(query.offset))

  const search = params.toString()
  return `${path}${search ? `?${search}` : ""}`
}

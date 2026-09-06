// Job detail query keys, tab type, and payload merge helpers extracted from
// JobDetail.tsx.
//
// The TanStack Query key tuples for the job detail + workflows queries, the
// tab identifier, deriving them from an id/search, merging a workflows-page
// payload into the detail payload, and reading the active tab from the URL.
// Pure over the job API payload types; lifting the types here lets the many
// JobDetail components that take them move out of the 3k-line file.
import type { JobDetailPayload, JobWorkflowsPayload } from "../../api/jobs"

// The tabs JobDetailView itself knows how to render. Anything else selectable
// (e.g. "tests") is a plugin-contributed tab whose validity comes from the
// current payload's ui_tabs, not from a hardcoded list here — see
// tabFromLocation.
export const CORE_JOB_TABS = ["summary", "review", "workflows", "attachments", "source", "artifacts"] as const
export type CoreJobTab = typeof CORE_JOB_TABS[number]
export type JobTab = CoreJobTab | (string & {})
export type JobDetailQueryKey = readonly ["jobs", string, "detail", string]
export type JobWorkflowsQueryKey = readonly ["jobs", string, "workflows", string]

export function jobDetailQueryKey(id: string | number, search: string): JobDetailQueryKey {
  return ["jobs", String(id), "detail", search] as const
}

export function jobWorkflowsQueryKey(id: string | number, search: string): JobWorkflowsQueryKey {
  return ["jobs", String(id), "workflows", search] as const
}

export function mergeJobWorkflowsPayload(payload: JobDetailPayload, workflows?: JobWorkflowsPayload): JobDetailPayload {
  if (!workflows) return payload

  return {
    ...payload,
    current_intent: workflows.current_intent ?? null,
    work_units: workflows.work_units || [],
    workflows: workflows.workflows,
    workflows_pagination: workflows.workflows_pagination,
    feature_flags: workflows.feature_flags,
    actions: workflows.actions,
    paths: workflows.paths
  }
}

export function jobDetailSearch(search: string) {
  const current = new URLSearchParams(search)
  const next = new URLSearchParams()
  const workflowsPage = current.get("workflows_page")
  if (workflowsPage) next.set("workflows_page", workflowsPage)
  const value = next.toString()
  return value ? `?${value}` : ""
}

export function tabFromLocation(pathname: string, search: string, pluginTabKeys: readonly string[] = []): JobTab {
  if (pathname.endsWith("/source")) return "source"

  const value = new URLSearchParams(search).get("tab")
  if (!value) return "summary"

  return (CORE_JOB_TABS as readonly string[]).includes(value) || pluginTabKeys.includes(value) ? value : "summary"
}

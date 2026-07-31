import { type DashboardEpicItem, type DashboardJobItem, type DashboardPayload, type DashboardSubject, type DashboardWorkflowItem } from "../../api/dashboard"


// Pure dashboard helpers extracted from Dashboard.tsx: link/query-string builders,
// column/sort resolution, date/currency/pluralization formatting, and small label
// utilities. No JSX and no hooks — a leaf the dashboard view and its extracted
// component clusters can share without importing back from the route file.

export type DashboardSortState = {
  column: string
  direction: string
  pending: boolean
  sortableColumns: string[]
  onSort: (column: string) => void
}

export function compactText(value: string) {
  return value.replace(/\s+/g, " ").trim()
}

export { formatCurrency } from "../../lib/format"

export function pluralize(count: number, singular: string) {
  return count === 1 ? singular : `${singular}s`
}

export function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

export function dashboardLinkFromSearch(path: string, search: string, updates: Record<string, string | number | null | undefined>) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

export { withRoutePrefix } from "../../lib/routing"

export function pageLink(pathname: string, search: string, page: number) {
  const params = new URLSearchParams(search)
  params.set("page", String(page))
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

export function bulkButtonClass(disabled: boolean, tone: "default" | "danger" = "default") {
  if (disabled) return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
  if (tone === "danger") return "rounded border border-red-300 px-3 py-1 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"

  return "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-white dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
}

export function epicTableColumns(columns: string[]) {
  return [ "checkbox", ...columns.filter((column) => column !== "checkbox") ]
}

export function uniqueValue(value: string, index: number, values: string[]) {
  return values.indexOf(value) === index
}

export function subjectLabel(subject: DashboardSubject, count: number) {
  const label = subject === "job" ? "job" : subject
  return count === 1 ? label : `${label}s`
}

export function sortValue(sort: Record<string, string>, key: string) {
  return sort[key]
}

export function sortableColumnFor(subject: DashboardSubject, column: string) {
  const aliases: Record<DashboardSubject, Record<string, string>> = {
    epic: {
      epic: "title",
      title: "title",
      updated: "updated_at"
    },
    job: {
      issue: "title",
      title: "title",
      started: "started_at"
    },
    workflow: {
      workflow: "title",
      title: "title",
      started: "started_at",
      finished: "finished_at"
    }
  }

  return aliases[subject][column] || column
}

export function columnAriaSort(subject: DashboardSubject, column: string, sortState: DashboardSortState) {
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || sortState.column !== sortColumn) return undefined

  return sortState.direction === "asc" ? "ascending" : "descending"
}

export function dashboardColumnLabel(subject: DashboardSubject, column: string, t: (key: string, opts?: Record<string, unknown>) => string) {
  // The workflow table uses "title" column key but displays it as "Workflow"
  const i18nKey = subject === "workflow" && column === "title" ? "workflow_title" : column
  return t(`column_label.${i18nKey}`, { defaultValue: humanizeOption(column) })
}

export function dashboardVisibleColumns(payload: DashboardPayload) {
  const allowed = new Set([
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.controls.columns.optional.map((column) => column.key)
  ])
  const normalized = [
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.preferences.visible_columns.map((column) => normalizeDashboardColumn(payload.subject, column))
  ]

  return normalized.filter((column, index, columns) => allowed.has(column) && columns.indexOf(column) === index)
}

export function normalizeDashboardColumn(subject: DashboardSubject, column: string) {
  if (subject === "job" && column === "title") return "issue"
  if (subject === "workflow" && column === "title") return "workflow"

  return column
}

export function jobDateValue(job: DashboardJobItem, column: string) {
  const values: Record<string, string | null> = {
    started: job.started_at,
    created_at: job.created_at,
    updated_at: job.updated_at,
    started_at: job.started_at,
    finished_at: job.finished_at,
    approved_at: job.approved_at,
    dependencies_overridden_at: job.dependencies_overridden_at,
    last_feedback_addressed_at: job.last_feedback_addressed_at,
    last_seen_comment_at: job.last_seen_comment_at,
    pr_mergeable_checked_at: job.pr_mergeable_checked_at
  }

  return values[column] || null
}

export function epicDateValue(epic: DashboardEpicItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: epic.created_at,
    updated_at: epic.updated_at,
    done_at: epic.done_at,
    archived_at: epic.archived_at
  }

  return values[column] || null
}

export function workflowDateValue(workflow: DashboardWorkflowItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: workflow.created_at,
    updated_at: workflow.updated_at,
    started_at: workflow.started_at,
    finished_at: workflow.finished_at,
    cleaned_up_at: workflow.cleaned_up_at
  }

  return values[column] || null
}

export function humanizeOption(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}


export { formatRelativeDate } from "../../lib/relativeTime"

export function dashboardEmptyFallbackPath(payload: DashboardPayload) {
  return payload.subject === "epic" ? payload.paths.new_epic_path : payload.paths.new_job_path
}

export function dashboardEmptyState(payload: DashboardPayload, t: (key: string, opts?: Record<string, unknown>) => string) {
  if (payload.simple_mode) {
    return {
      title: t("simple_empty_title"),
      description: t("simple_empty_description"),
      actionPath: payload.paths.new_epic_path,
      actionText: t("new_feature")
    }
  }

  const subject = subjectLabel(payload.subject, 2)
  if (payload.setup && !payload.setup.complete) {
    const setupDescription = payload.setup.next_step === "credentials"
      ? t("setup_credentials_description")
      : t("setup_description")

    return {
      title: t("empty_title", { subject: capitalizeLabel(subject) }),
      description: setupDescription,
      actionPath: payload.setup.paths.setup_path,
      actionText: t("open_setup")
    }
  }

  return {
    title: t("empty_title", { subject: capitalizeLabel(subject) }),
    description: t("empty_description", { subject }),
    actionPath: dashboardEmptyFallbackPath(payload),
    actionText: payload.subject === "epic" ? t("create_epic") : t("create_direct_job")
  }
}

export function capitalizeLabel(value: string) {
  return value.charAt(0).toUpperCase() + value.slice(1)
}

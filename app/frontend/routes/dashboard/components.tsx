import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { dashboardColumnLabel, humanizeOption, sortableColumnFor, withRoutePrefix, type DashboardSortState } from "./helpers"
import type { ReactNode } from "react"
import { Children, useEffect, useState } from "react"
import { Link } from "react-router-dom"
import { useT } from "../../hooks/useT"
import { StatusPill } from "../../components/StatusPill"
import { workflowSlug } from "../../lib/slugs"
import { type DashboardEpicItem, type DashboardRepository, type DashboardSubject, type DashboardWorkflowItem } from "../../api/dashboard"


// Shared dashboard presentational primitives extracted from Dashboard.tsx:
// small pills/badges/links/labels reused across the kanban board and the
// job/epic tables. A leaf so the clusters can share them without importing
// back from the route file.

export function WorkflowBadges({ state, triggerAriaPrefix, triggerKind }: { state: string; triggerAriaPrefix: string; triggerKind: string | null }) {
  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      {triggerKind ? <WorkflowTriggerPill ariaPrefix={triggerAriaPrefix} triggerKind={triggerKind} /> : null}
      <StatusPill state={state} />
    </span>
  )
}

export function PendingJobTitle({ pending, title }: { pending: boolean; title: string }) {
  const { t } = useT("dashboard")
  if (!pending) return <>{title}</>

  return (
    <span className="inline-flex min-w-0 items-center gap-1 italic text-gray-500 dark:text-gray-400">
      <span aria-hidden="true" className="inline-block h-3 w-3 shrink-0 animate-spin rounded-full border-2 border-gray-300 border-t-gray-500 dark:border-gray-700 dark:border-t-gray-300" />
      <span>{t("generating_title")}</span>
    </span>
  )
}

export function WorkflowTriggerPill({ ariaPrefix, triggerKind }: { ariaPrefix: string; triggerKind: string }) {
  const { t } = useT()
  const className = workflowTriggerClassName(triggerKind)
  const label = t(`trigger_kind.${triggerKind}`, { defaultValue: triggerKind.replaceAll("_", " ") })

  return (
    <span aria-label={`${ariaPrefix}: ${label}`} className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium capitalize ring-1 ${className}`} data-status-pill="true">
      <span>{label}</span>
    </span>
  )
}

export function workflowTriggerClassName(triggerKind: string) {
  if (triggerKind === "chat_feedback") {
    return "bg-indigo-100 text-indigo-700 ring-indigo-200 dark:bg-indigo-950/50 dark:text-indigo-200 dark:ring-indigo-800"
  }

  return "bg-gray-100 text-gray-700 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700"
}

export function MetadataLine({ children, className }: { children: ReactNode; className: string }) {
  const items = Children.toArray(children)
  return (
    <div className={className}>
      {items.map((item, index) => (
        <span className="inline-flex items-center gap-x-1.5" key={index}>
          {index > 0 ? <span aria-hidden="true" className="select-none">·</span> : null}
          {item}
        </span>
      ))}
    </div>
  )
}

export function ExternalMetadataLink({ children, className = "text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300", href }: { children: ReactNode; className?: string; href: string | null }) {
  if (!href) return <span className={className}>{children}</span>

  return <a className={className} href={href} rel="noopener noreferrer" target="_blank">{children}</a>
}

export function RepositorySlugLink({ className = "font-mono text-xs text-gray-500 hover:text-blue-700 hover:underline dark:text-gray-400 dark:hover:text-blue-300", prefix, repository }: { className?: string; prefix: string; repository: DashboardRepository }) {
  return <Link className={className} to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
}

export function EpicStuckBadge({ stuck }: { stuck: boolean }) {
  const { t } = useT("dashboard")
  if (!stuck) return null

  return (
    <span
      aria-label={t("needs_attention")}
      className="inline-flex items-center rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/60 dark:text-amber-200 dark:ring-amber-800"
      title={t("needs_attention_title")}
    >
      {t("needs_attention")}
    </span>
  )
}

export function EpicCommitsBehindBadge({ commits }: { commits: number | null }) {
  const { t } = useT("dashboard")
  if (!commits || commits <= 0) return null

  const className = commits >= 20
    ? "inline-flex items-center rounded bg-red-100 px-1.5 py-0.5 text-xs font-medium text-red-700 ring-1 ring-red-200 dark:bg-red-950/50 dark:text-red-200 dark:ring-red-800"
    : "inline-flex items-center rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/50 dark:text-amber-200 dark:ring-amber-800"

  return (
    <span className={className}>
      {t("epic_commits_behind", { count: commits })}
    </span>
  )
}

export function workflowLabel(workflow: Pick<DashboardWorkflowItem, "id" | "slug">) {
  return workflow.slug || workflowSlug(workflow.id)
}

export function NeutralStatePill({ state }: { state: string }) {
  const { t } = useT()
  const label = t(`status.${state.toLowerCase()}`, { defaultValue: state.replace(/_/g, " ") })
  return <span className="inline-flex whitespace-nowrap rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium capitalize text-gray-700 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700">{label}</span>
}

export function OwnerBadge({ badge, fallback = null }: { badge: { label: string; kind: string } | null; fallback?: string | null }) {
  if (!badge && !fallback) return null

  const label = badge?.label || fallback
  const className = badge?.kind === "claimable"
    ? "rounded bg-amber-50 px-1.5 py-0.5 text-xs text-amber-700 ring-1 ring-amber-200 dark:bg-amber-950 dark:text-amber-200 dark:ring-amber-800"
    : "rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-600 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:ring-gray-700"

  return <span className={className}>{label}</span>
}

const EPIC_PROGRESS_SEGMENTS = [
  { state: "merged", barColor: "bg-emerald-700" },
  { state: "approved", barColor: "bg-green-500" },
  { state: "implemented", barColor: "bg-cyan-500" },
  { state: "blocked_by_epic", barColor: "bg-amber-400" },
]

export function EpicProgressBar({ epic, fullWidth = false }: { epic: DashboardEpicItem; fullWidth?: boolean }) {
  const { t } = useT("dashboard")
  if (epic.state !== "in_progress" || epic.jobs_count === 0) return null

  const segments = EPIC_PROGRESS_SEGMENTS.map(({ state, barColor }) => {
    const count = epic.job_state_counts[state] ?? 0
    return { state, barColor, count, percent: (count / epic.jobs_count) * 100 }
  })

  const titleText = segments
    .filter(s => s.count > 0)
    .map(s => `${s.count} ${humanizeOption(s.state)}`)
    .join(", ") || undefined

  return (
    <div
      aria-label={t("epic_progress_label")}
      className={fullWidth ? "flex h-1.5 w-full overflow-hidden rounded-b bg-gray-200 dark:bg-gray-700" : "flex h-1.5 w-20 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700"}
      role="progressbar"
      title={titleText}
    >
      {segments.map(({ state, barColor, percent }) =>
        percent > 0 ? <div className={`h-1.5 transition-[width] ${barColor}`} key={state} style={{ width: `${percent}%` }} /> : null
      )}
    </div>
  )
}

export function SortableColumnHeader({ subject, column, sortState }: { subject: DashboardSubject; column: string; sortState: DashboardSortState }) {
  const { t } = useT("dashboard")
  const label = dashboardColumnLabel(subject, column, t)
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || !sortState.sortableColumns.includes(sortColumn)) return <span>{label}</span>

  const active = sortState.column === sortColumn
  const nextDirection = active && sortState.direction === "asc" ? "desc" : "asc"
  const directionLabel = nextDirection === "asc" ? t("ascending") : t("descending")

  return (
    <button
      aria-label={t("sort_by", { label, direction: directionLabel.toLowerCase() })}
      className={`inline-flex items-center gap-1 text-left font-semibold uppercase ${active ? "text-gray-900 dark:text-gray-100" : "text-gray-500 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-100"}`}
      disabled={sortState.pending}
      onClick={() => sortState.onSort(column)}
      type="button"
    >
      <span>{label}</span>
      {active ? <span aria-hidden="true" className="text-[11px] leading-none text-gray-700 dark:text-gray-300">{sortState.direction === "asc" ? "↑" : "↓"}</span> : null}
    </button>
  )
}

export function TimestampCell({ value }: { value: string | null }) {
  return (
    <td className="px-4 py-3 text-gray-500 dark:text-gray-400">
      <RelativeTimestamp value={value} />
    </td>
  )
}

export function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}

export { RelativeTimestamp }

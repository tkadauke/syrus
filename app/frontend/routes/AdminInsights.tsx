import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { withRoutePrefix } from "../lib/routing"
import { useT } from "../hooks/useT"
import { acceptRemoveMemoryInsight, fetchAdminInsights, promoteInsightMemory, type AdminInsightSuggestion, type PaginationMeta } from "../api/insights"
import { errorMessage } from "../lib/errorMessage"

type StateFilter = "pending" | "accepted" | "dismissed" | "all"

export function AdminInsightsRoute() {
  const { t } = useT("insights")
  const [page, setPage] = useState(1)

  const query = useQuery({
    queryKey: ["admin", "insights", page],
    queryFn: () => fetchAdminInsights(page)
  })

  if (query.isPending) {
    return (
      <main aria-label={t("aria_admin_insights")} className="p-6 text-sm text-gray-600 dark:text-gray-400">
        {t("loading")}
      </main>
    )
  }

  if (query.isError) {
    return (
      <main aria-label={t("aria_admin_insights")} className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">{errorMessage(query.error, t("load_error"))}</p>
      </main>
    )
  }

  return <AdminInsightsList suggestions={query.data.suggestions} meta={query.data.meta} page={page} onPageChange={setPage} />
}

function AdminInsightsList({
  suggestions,
  meta,
  page,
  onPageChange
}: {
  suggestions: AdminInsightSuggestion[]
  meta: PaginationMeta
  page: number
  onPageChange: (page: number) => void
}) {
  const { t } = useT("insights")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const [stateFilter, setStateFilter] = useState<StateFilter>("pending")

  function handleFilterChange(filter: StateFilter) {
    setStateFilter(filter)
    onPageChange(1)
  }

  const filtered = suggestions.filter((s) => stateFilter === "all" || s.state === stateFilter)
  const counts = {
    pending: suggestions.filter((s) => s.state === "pending").length,
    accepted: suggestions.filter((s) => s.state === "accepted").length,
    dismissed: suggestions.filter((s) => s.state === "dismissed").length
  }

  const filterTabs: Array<{ key: StateFilter; label: string; count: number }> = [
    { key: "pending", label: t("filter_pending"), count: counts.pending },
    { key: "accepted", label: t("filter_accepted"), count: counts.accepted },
    { key: "dismissed", label: t("filter_dismissed"), count: counts.dismissed },
    { key: "all", label: t("filter_all"), count: suggestions.length }
  ]

  const firstItem = meta.total === 0 ? 0 : (page - 1) * meta.per_page + 1
  const lastItem = Math.min(page * meta.per_page, meta.total)

  return (
    <main aria-label={t("aria_admin_insights")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("admin_eyebrow")}</p>
        <h1 className="mt-1 text-3xl font-semibold text-gray-900 dark:text-gray-100">{t("admin_title")}</h1>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t("admin_subtitle")}</p>
      </header>

      <div className="flex items-center justify-between gap-4">
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
          {t("suggestions_heading")}
        </h2>
        <nav aria-label={t("filter_aria")} className="flex gap-1">
          {filterTabs.map((tab) => (
            <button
              className={`rounded px-3 py-1 text-sm font-medium transition-colors ${stateFilter === tab.key ? "bg-terracotta-600 text-white" : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"}`}
              key={tab.key}
              onClick={() => handleFilterChange(tab.key)}
              type="button"
            >
              {tab.label}
              <span className="ml-1.5 rounded-full bg-gray-100 px-1.5 py-0.5 text-xs text-gray-700 dark:bg-gray-700 dark:text-gray-300">
                {tab.count}
              </span>
            </button>
          ))}
        </nav>
      </div>

      {filtered.length === 0 ? (
        <div className="rounded border border-gray-200 bg-white p-8 text-center text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
          {t("empty")}
        </div>
      ) : (
        <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700">
          <table className="w-full text-sm">
            <thead className="border-b border-gray-200 bg-gray-50 dark:border-gray-700 dark:bg-gray-800">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_title")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_repository")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_user")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_severity")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_confidence")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_state")}</th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("col_actions")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-900">
              {filtered.map((suggestion) => (
                <AdminSuggestionRow key={suggestion.id} prefix={prefix} suggestion={suggestion} />
              ))}
            </tbody>
          </table>
        </div>
      )}

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
          <span>{t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total })}</span>
          <div className="flex gap-2">
            {page > 1 ? (
              <button
                className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
                onClick={() => onPageChange(page - 1)}
                type="button"
              >
                {t("pagination_previous")}
              </button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">
                {t("pagination_previous")}
              </span>
            )}
            {page < meta.total_pages ? (
              <button
                className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
                onClick={() => onPageChange(page + 1)}
                type="button"
              >
                {t("pagination_next")}
              </button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">
                {t("pagination_next")}
              </span>
            )}
          </div>
        </div>
      )}
    </main>
  )
}

function AdminSuggestionRow({ suggestion, prefix }: { suggestion: AdminInsightSuggestion; prefix: string }) {
  const { t } = useT("insights")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState(false)

  const promoteMutation = useMutation({
    mutationFn: () => promoteInsightMemory(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
      queryClient.invalidateQueries({ queryKey: ["admin", "insights"] })
    },
    onError: (err) => setError(errorMessage(err, t("promote_error")))
  })

  const acceptRemoveMemoryMutation = useMutation({
    mutationFn: () => acceptRemoveMemoryInsight(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
      queryClient.invalidateQueries({ queryKey: ["admin", "insights"] })
    },
    onError: (err) => setError(errorMessage(err, t("remove_memory_error")))
  })

  return (
    <>
      <tr className="hover:bg-gray-50 dark:hover:bg-gray-800/50">
        <td className="px-4 py-3">
          <div className="max-w-sm">
            <button
              className="text-left text-sm font-medium text-gray-900 underline-offset-2 hover:underline dark:text-gray-100"
              onClick={() => setExpanded((v) => !v)}
              type="button"
            >
              {suggestion.title}
            </button>
            <span className="ml-2 rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
              {suggestion.category}
            </span>
            <span className={`ml-2 rounded px-1.5 py-0.5 text-xs ${suggestion.proposal_type === "remove_memory" ? "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"}`}>
              {t(`proposal_${suggestion.proposal_type}`)}
            </span>
          </div>
        </td>
        <td className="px-4 py-3">
          <Link
            className="text-terracotta-700 underline hover:no-underline dark:text-terracotta-400"
            to={withRoutePrefix(suggestion.repository.insights_path, prefix)}
          >
            {suggestion.repository.slug}
          </Link>
        </td>
        <td className="px-4 py-3 text-xs text-gray-600 dark:text-gray-400">
          {suggestion.user.display_name}
        </td>
        <td className="px-4 py-3">
          <SeverityPill severity={suggestion.severity} />
        </td>
        <td className="px-4 py-3 text-xs text-gray-600 dark:text-gray-400">
          {Math.round(suggestion.confidence * 100)}%
        </td>
        <td className="px-4 py-3">
          <StatePill state={suggestion.state} />
        </td>
        <td className="px-4 py-3">
          <div className="flex items-center gap-2">
            <Link
              className="text-xs text-terracotta-700 underline hover:no-underline dark:text-terracotta-400"
              to={withRoutePrefix(suggestion.job_path, prefix)}
            >
              {t("view_job")}
            </Link>
            {suggestion.has_memory_suggestion && (
              <button
                className="rounded border border-gray-300 px-2 py-0.5 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
                disabled={promoteMutation.isPending}
                onClick={() => promoteMutation.mutate()}
                type="button"
              >
                {promoteMutation.isPending ? t("promoting") : t("promote_to_instance")}
              </button>
            )}
            {suggestion.state === "pending" && suggestion.proposal_type === "remove_memory" && (
              <button
                className="rounded border border-red-300 px-2 py-0.5 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950/40"
                disabled={acceptRemoveMemoryMutation.isPending}
                onClick={() => acceptRemoveMemoryMutation.mutate()}
                type="button"
              >
                {acceptRemoveMemoryMutation.isPending ? t("removing_memory") : t("accept_remove_memory")}
              </button>
            )}
          </div>
        </td>
      </tr>
      {expanded && (
        <tr className="bg-gray-50 dark:bg-gray-800/50">
          <td className="px-4 pb-4 pt-0" colSpan={7}>
            {notice && <p className="mb-2 text-xs text-green-700 dark:text-green-400">{notice}</p>}
            {error && <p className="mb-2 text-xs text-red-700 dark:text-red-400">{error}</p>}
            {suggestion.suggested_prompt && (
              <div className="mt-2">
                <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("suggested_prompt_label")}</p>
                <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-white p-3 text-xs text-gray-700 ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-700">
                  {suggestion.suggested_prompt}
                </pre>
              </div>
            )}
            {suggestion.memory_suggestion && (
              <div className="mt-2">
                <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("memory_suggestion_label")}</p>
                <pre className="mt-1 whitespace-pre-wrap rounded bg-white p-3 text-xs text-gray-700 ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-700">
                  {suggestion.memory_suggestion}
                </pre>
              </div>
            )}
            {suggestion.proposal_type === "remove_memory" && (
              <div className="mt-2 rounded border border-red-200 bg-red-50 p-3 dark:border-red-900/50 dark:bg-red-950/20">
                <p className="text-xs font-medium uppercase text-red-700 dark:text-red-300">
                  {t("remove_memory_label", { id: suggestion.target_memory_id })}
                </p>
                {suggestion.stale_memory_text && (
                  <pre className="mt-1 whitespace-pre-wrap rounded bg-white p-3 text-xs text-red-900 ring-1 ring-red-100 dark:bg-gray-950 dark:text-red-200 dark:ring-red-900/60">
                    {suggestion.stale_memory_text}
                  </pre>
                )}
                {suggestion.stale_memory_evidence && (
                  <p className="mt-2 whitespace-pre-wrap text-xs text-red-800 dark:text-red-200">
                    {suggestion.stale_memory_evidence}
                  </p>
                )}
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  )
}

function SeverityPill({ severity }: { severity: string }) {
  const { t } = useT("insights")
  const classes =
    severity === "high"
      ? "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"
      : severity === "medium"
        ? "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"
        : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-400"
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`severity_${severity}`)}
    </span>
  )
}

function StatePill({ state }: { state: string }) {
  const { t } = useT("insights")
  const classes =
    state === "accepted"
      ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-300"
      : state === "dismissed"
        ? "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
        : "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`state_${state}`)}
    </span>
  )
}

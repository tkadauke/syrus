import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button, buttonClasses } from "@app/components/Button"
import { PILL_TONE_CLASSES, TonePill } from "@app/components/StatusPill"
import { DataTable, Notice, Page, PageHeading, Section, SectionHeading, Text, Toolbar } from "@app/components/ui"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { withRoutePrefix } from "@app/lib/routing"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { acceptRemoveMemoryInsight, fetchAdminInsights, promoteInsightMemory, type AdminInsightSuggestion, type PaginationMeta } from "../api/insights"
import { errorMessage } from "@app/lib/errorMessage"

type StateFilter = "pending" | "accepted" | "dismissed" | "retired" | "all"

export function AdminInsightsRoute() {
  const { t } = useT("agent_insights")
  usePageTitle(t("admin_title"))
  const [page, setPage] = useState(1)
  const [stateFilter, setStateFilter] = useState<StateFilter>("pending")

  const query = useQuery({
    queryKey: ["admin", "insights", stateFilter, page],
    queryFn: () => fetchAdminInsights(page, 20, stateFilter)
  })

  if (query.isPending) {
    return (
      <Page.Root aria-label={t("aria_admin_insights")} gutter="responsive" size="wide">
        <AdminInsightsHeader />
        <Notice>{t("loading")}</Notice>
      </Page.Root>
    )
  }

  if (query.isError) {
    return (
      <Page.Root aria-label={t("aria_admin_insights")} gutter="responsive" size="wide">
        <AdminInsightsHeader />
        <Notice tone="danger">{errorMessage(query.error, t("load_error"))}</Notice>
      </Page.Root>
    )
  }

  return (
    <AdminInsightsList
      suggestions={query.data.suggestions}
      meta={query.data.meta}
      page={page}
      stateFilter={stateFilter}
      onFilterChange={setStateFilter}
      onPageChange={setPage}
    />
  )
}

function AdminInsightsHeader() {
  const { t } = useT("agent_insights")
  return (
    <Page.Header className="border-b border-border pb-4">
      <Text className="font-medium uppercase" variant="caption" tone="muted">
        {t("admin_eyebrow")}
      </Text>
      <PageHeading>{t("admin_title")}</PageHeading>
      <Page.Description>{t("admin_subtitle")}</Page.Description>
    </Page.Header>
  )
}

function AdminInsightsList({
  suggestions,
  meta,
  page,
  stateFilter,
  onFilterChange,
  onPageChange
}: {
  suggestions: AdminInsightSuggestion[]
  meta: PaginationMeta
  page: number
  stateFilter: StateFilter
  onFilterChange: (filter: StateFilter) => void
  onPageChange: (page: number) => void
}) {
  const { t } = useT("agent_insights")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  function handleFilterChange(filter: StateFilter) {
    onFilterChange(filter)
    onPageChange(1)
  }

  const filterTabs: Array<{ key: StateFilter; label: string; count: number }> = [
    { key: "pending", label: t("filter_pending"), count: meta.counts.pending },
    { key: "accepted", label: t("filter_accepted"), count: meta.counts.accepted },
    { key: "dismissed", label: t("filter_dismissed"), count: meta.counts.dismissed },
    { key: "retired", label: t("filter_retired"), count: meta.counts.retired },
    { key: "all", label: t("filter_all"), count: meta.counts.all }
  ]

  const firstItem = meta.total === 0 ? 0 : (page - 1) * meta.per_page + 1
  const lastItem = Math.min(page * meta.per_page, meta.total)

  return (
    <Page.Root aria-label={t("aria_admin_insights")} gutter="responsive" size="wide">
      <AdminInsightsHeader />

      <Page.Nav>
        <Toolbar className="justify-between gap-4">
          <SectionHeading>{t("suggestions_heading")}</SectionHeading>
          <nav aria-label={t("filter_aria")} className="flex gap-1">
            {filterTabs.map((tab) => (
              <Button key={tab.key} onClick={() => handleFilterChange(tab.key)} size="sm" variant={stateFilter === tab.key ? "primary" : "secondary"}>
                {tab.label}
                <span className={`ml-1.5 rounded-full px-1.5 py-0.5 text-xs ${stateFilter === tab.key ? "bg-white/20 text-current" : PILL_TONE_CLASSES.gray}`}>
                  {tab.count}
                </span>
              </Button>
            ))}
          </nav>
        </Toolbar>
      </Page.Nav>

      {suggestions.length === 0 ? (
        <Notice className="p-8 text-center">{t("empty")}</Notice>
      ) : (
        <Section.Root className="overflow-hidden p-0">
          <DataTable.Root wrapperClassName="rounded-none border-0">
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("col_title")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_repository")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_user")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_severity")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_confidence")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_state")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("col_actions")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {suggestions.map((suggestion) => (
                <AdminSuggestionRow key={suggestion.id} prefix={prefix} suggestion={suggestion} />
              ))}
            </DataTable.Body>
          </DataTable.Root>
        </Section.Root>
      )}

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
          <span>{t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total })}</span>
          <div className="flex gap-2">
            {page > 1 ? (
              <Button onClick={() => onPageChange(page - 1)} size="sm" variant="secondary">
                {t("pagination_previous")}
              </Button>
            ) : (
              <span className={buttonClasses("secondary", "sm", "opacity-50")}>{t("pagination_previous")}</span>
            )}
            {page < meta.total_pages ? (
              <Button onClick={() => onPageChange(page + 1)} size="sm" variant="secondary">
                {t("pagination_next")}
              </Button>
            ) : (
              <span className={buttonClasses("secondary", "sm", "opacity-50")}>{t("pagination_next")}</span>
            )}
          </div>
        </div>
      )}
    </Page.Root>
  )
}

function AdminSuggestionRow({ suggestion, prefix }: { suggestion: AdminInsightSuggestion; prefix: string }) {
  const { t } = useT("agent_insights")
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
      <DataTable.Row className="hover:bg-gray-50 dark:hover:bg-gray-800/50">
        <DataTable.Cell>
          <div className="max-w-sm">
            <button
              className="text-left text-sm font-medium text-text-primary underline-offset-2 hover:underline"
              onClick={() => setExpanded((v) => !v)}
              type="button"
            >
              {suggestion.title}
            </button>
            <span className="ml-2">
              <TonePill tone="gray">{suggestion.category}</TonePill>
            </span>
            <span className="ml-2">
              <TonePill tone={suggestion.proposal_type === "remove_memory" ? "red" : "gray"}>{t(`proposal_${suggestion.proposal_type}`)}</TonePill>
            </span>
          </div>
        </DataTable.Cell>
        <DataTable.Cell>
          <Link
            className="text-brand-emphasis underline hover:no-underline dark:text-brand-emphasis"
            to={withRoutePrefix(suggestion.repository.insights_path, prefix)}
          >
            {suggestion.repository.slug}
          </Link>
        </DataTable.Cell>
        <DataTable.Cell className="text-xs text-text-secondary">{suggestion.user.display_name}</DataTable.Cell>
        <DataTable.Cell>
          <SeverityPill severity={suggestion.severity} />
        </DataTable.Cell>
        <DataTable.Cell className="text-xs text-text-secondary">{Math.round(suggestion.confidence * 100)}%</DataTable.Cell>
        <DataTable.Cell>
          <StatePill state={suggestion.state} />
        </DataTable.Cell>
        <DataTable.Cell>
          <div className="flex items-center gap-2">
            <Link
              className="text-xs text-brand-emphasis underline hover:no-underline dark:text-brand-emphasis"
              to={withRoutePrefix(suggestion.job_path, prefix)}
            >
              {t("view_job")}
            </Link>
            {suggestion.has_memory_suggestion && (
              <Button disabled={promoteMutation.isPending} onClick={() => promoteMutation.mutate()} size="sm" variant="secondary">
                {promoteMutation.isPending ? t("promoting") : t("promote_to_instance")}
              </Button>
            )}
            {suggestion.state === "pending" && suggestion.proposal_type === "remove_memory" && (
              <Button size="sm" variant="danger" disabled={acceptRemoveMemoryMutation.isPending} onClick={() => acceptRemoveMemoryMutation.mutate()}>
                {acceptRemoveMemoryMutation.isPending ? t("removing_memory") : t("accept_remove_memory")}
              </Button>
            )}
          </div>
        </DataTable.Cell>
      </DataTable.Row>
      {expanded && (
        <DataTable.Row className="bg-gray-50 dark:bg-gray-800/50">
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
                <p className="text-xs font-medium uppercase text-red-700 dark:text-red-300">{t("remove_memory_label", { id: suggestion.target_memory_id })}</p>
                {suggestion.stale_memory_text && (
                  <pre className="mt-1 whitespace-pre-wrap rounded bg-white p-3 text-xs text-red-900 ring-1 ring-red-100 dark:bg-gray-950 dark:text-red-200 dark:ring-red-900/60">
                    {suggestion.stale_memory_text}
                  </pre>
                )}
                {suggestion.stale_memory_evidence && (
                  <p className="mt-2 whitespace-pre-wrap text-xs text-red-800 dark:text-red-200">{suggestion.stale_memory_evidence}</p>
                )}
              </div>
            )}
            {suggestion.state === "retired" && (
              <div className="mt-2 rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
                <p className="font-medium text-gray-700 dark:text-gray-200">{t("retired_heading")}</p>
                {suggestion.retired_reason && <p className="mt-1 whitespace-pre-wrap">{suggestion.retired_reason}</p>}
                {suggestion.superseded_by_insight_id && <p className="mt-1">{t("superseded_by_insight_label", { id: suggestion.superseded_by_insight_id })}</p>}
                {suggestion.superseded_by_job_slug && <p className="mt-1">{t("superseded_by_job_label", { slug: suggestion.superseded_by_job_slug })}</p>}
              </div>
            )}
          </td>
        </DataTable.Row>
      )}
    </>
  )
}

function SeverityPill({ severity }: { severity: string }) {
  const { t } = useT("agent_insights")
  const tone = severity === "high" ? "red" : severity === "medium" ? "amber" : "gray"
  return <TonePill tone={tone}>{t(`severity_${severity}`)}</TonePill>
}

function StatePill({ state }: { state: string }) {
  const { t } = useT("agent_insights")
  const tone = state === "accepted" ? "green" : state === "pending" ? "amber" : "gray"
  return <TonePill tone={tone}>{t(`state_${state}`)}</TonePill>
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminInsightsRoute

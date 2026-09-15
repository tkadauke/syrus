import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { useLocation } from "react-router-dom"
import { Badge, Button, CodeSurface, DataTable, LinkText, Notice, Page, Pill, Section, Text, Toolbar } from "@app/components/ui"
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
      <Page.Root aria-label={t("aria_admin_insights")} size="wide">
        <AdminInsightsHeader />
        <Notice>{t("loading")}</Notice>
      </Page.Root>
    )
  }

  if (query.isError) {
    return (
      <Page.Root aria-label={t("aria_admin_insights")} size="wide">
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
    <Page.Header>
      <Page.HeadingGroup>
        <Text variant="label" muted>
          {t("admin_eyebrow")}
        </Text>
        <Page.Title>{t("admin_title")}</Page.Title>
        <Page.Description>{t("admin_subtitle")}</Page.Description>
      </Page.HeadingGroup>
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
    <Page.Root aria-label={t("aria_admin_insights")} size="wide">
      <AdminInsightsHeader />

      <Toolbar aria-label={t("filter_aria")} align="center" gap="md">
        <Section.Title>{t("suggestions_heading")}</Section.Title>
        <nav className="flex flex-wrap gap-1">
          {filterTabs.map((tab) => (
            <Button key={tab.key} onClick={() => handleFilterChange(tab.key)} size="sm" variant={stateFilter === tab.key ? "primary" : "secondary"}>
              {tab.label}
              <Badge>{tab.count}</Badge>
            </Button>
          ))}
        </nav>
      </Toolbar>

      {suggestions.length === 0 ? (
        <Section.Root>
          <Text className="text-center" muted>
            {t("empty")}
          </Text>
        </Section.Root>
      ) : (
        <DataTable.Root>
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
      )}

      {meta.total_pages > 1 && (
        <Toolbar className="text-sm text-text-muted">
          <span>{t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total })}</span>
          <div className="flex gap-2">
            {page > 1 ? (
              <Button onClick={() => onPageChange(page - 1)} size="sm" variant="secondary">
                {t("pagination_previous")}
              </Button>
            ) : (
              <span className="rounded border border-border px-3 py-1 text-text-subtle">{t("pagination_previous")}</span>
            )}
            {page < meta.total_pages ? (
              <Button onClick={() => onPageChange(page + 1)} size="sm" variant="secondary">
                {t("pagination_next")}
              </Button>
            ) : (
              <span className="rounded border border-border px-3 py-1 text-text-subtle">{t("pagination_next")}</span>
            )}
          </div>
        </Toolbar>
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
      <DataTable.Row interactive>
        <DataTable.Cell>
          <div className="max-w-sm">
            <button className="text-left text-sm font-medium text-link underline-offset-2 hover:underline" onClick={() => setExpanded((v) => !v)} type="button">
              {suggestion.title}
            </button>
            <Badge className="ml-2">{suggestion.category}</Badge>
            <Badge className="ml-2" tone={suggestion.proposal_type === "remove_memory" ? "danger" : "neutral"}>
              {t(`proposal_${suggestion.proposal_type}`)}
            </Badge>
          </div>
        </DataTable.Cell>
        <DataTable.Cell>
          <LinkText to={withRoutePrefix(suggestion.repository.insights_path, prefix)}>{suggestion.repository.slug}</LinkText>
        </DataTable.Cell>
        <DataTable.Cell className="text-xs text-text-muted">{suggestion.user.display_name}</DataTable.Cell>
        <DataTable.Cell>
          <SeverityPill severity={suggestion.severity} />
        </DataTable.Cell>
        <DataTable.Cell className="text-xs text-text-muted">{Math.round(suggestion.confidence * 100)}%</DataTable.Cell>
        <DataTable.Cell>
          <StatePill state={suggestion.state} />
        </DataTable.Cell>
        <DataTable.Cell>
          <div className="flex items-center gap-2">
            <LinkText className="text-xs" to={withRoutePrefix(suggestion.job_path, prefix)}>
              {t("view_job")}
            </LinkText>
            {suggestion.has_memory_suggestion && (
              <Button disabled={promoteMutation.isPending} onClick={() => promoteMutation.mutate()} size="sm" variant="secondary">
                {promoteMutation.isPending ? t("promoting") : t("promote_to_instance")}
              </Button>
            )}
            {suggestion.state === "pending" && suggestion.proposal_type === "remove_memory" && (
              <Button disabled={acceptRemoveMemoryMutation.isPending} onClick={() => acceptRemoveMemoryMutation.mutate()} size="sm" variant="danger">
                {acceptRemoveMemoryMutation.isPending ? t("removing_memory") : t("accept_remove_memory")}
              </Button>
            )}
          </div>
        </DataTable.Cell>
      </DataTable.Row>
      {expanded && (
        <DataTable.Row groupHeader>
          <DataTable.Cell className="pb-4 pt-0" colSpan={7}>
            {notice && (
              <Text className="mb-2" tone="success" variant="caption">
                {notice}
              </Text>
            )}
            {error && (
              <Text className="mb-2" tone="danger" variant="caption">
                {error}
              </Text>
            )}
            {suggestion.suggested_prompt && (
              <div className="mt-2">
                <Text variant="label" muted>
                  {t("suggested_prompt_label")}
                </Text>
                <CodeSurface className="mt-1" code={suggestion.suggested_prompt} maxHeightClassName="max-h-40" mode="multiline">
                  {suggestion.suggested_prompt}
                </CodeSurface>
              </div>
            )}
            {suggestion.memory_suggestion && (
              <div className="mt-2">
                <Text variant="label" muted>
                  {t("memory_suggestion_label")}
                </Text>
                <CodeSurface className="mt-1" code={suggestion.memory_suggestion} mode="multiline">
                  {suggestion.memory_suggestion}
                </CodeSurface>
              </div>
            )}
            {suggestion.proposal_type === "remove_memory" && (
              <Notice className="mt-2" tone="danger">
                <Text tone="danger" variant="label">
                  {t("remove_memory_label", { id: suggestion.target_memory_id })}
                </Text>
                {suggestion.stale_memory_text && (
                  <CodeSurface className="mt-1" code={suggestion.stale_memory_text} mode="multiline">
                    {suggestion.stale_memory_text}
                  </CodeSurface>
                )}
                {suggestion.stale_memory_evidence && (
                  <Text className="mt-2 whitespace-pre-wrap" tone="danger" variant="caption">
                    {suggestion.stale_memory_evidence}
                  </Text>
                )}
              </Notice>
            )}
            {suggestion.state === "retired" && (
              <Notice className="mt-2" title={t("retired_heading")}>
                {suggestion.retired_reason && <Text className="mt-1 whitespace-pre-wrap">{suggestion.retired_reason}</Text>}
                {suggestion.superseded_by_insight_id && (
                  <Text className="mt-1">{t("superseded_by_insight_label", { id: suggestion.superseded_by_insight_id })}</Text>
                )}
                {suggestion.superseded_by_job_slug && <Text className="mt-1">{t("superseded_by_job_label", { slug: suggestion.superseded_by_job_slug })}</Text>}
              </Notice>
            )}
          </DataTable.Cell>
        </DataTable.Row>
      )}
    </>
  )
}

function SeverityPill({ severity }: { severity: string }) {
  const { t } = useT("agent_insights")
  return <Pill tone={severity === "high" ? "danger" : severity === "medium" ? "warning" : "neutral"}>{t(`severity_${severity}`)}</Pill>
}

function StatePill({ state }: { state: string }) {
  const { t } = useT("agent_insights")
  return <Pill tone={state === "accepted" ? "success" : state === "pending" ? "warning" : "neutral"}>{t(`state_${state}`)}</Pill>
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminInsightsRoute

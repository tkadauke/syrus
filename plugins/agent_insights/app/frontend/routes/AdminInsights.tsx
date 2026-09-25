import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button, Notice, Page, Text, Toolbar } from "@app/components/ui"
import { TonePill } from "@app/components/StatusPill"
import { AdminFiltersLayout } from "@app/components/AdminFiltersLayout"
import { AdminEventLogTable, AdminEventPanelMessage, type AdminDataTablePanelConfig, type AdminEventLogTableColumn } from "@app/components/AdminEventLogPanel"
import { AdminSmartFolderNav } from "@app/components/AdminSmartFolderNav"
import { FilterBar } from "@app/components/FilterBar"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { adminSmartFolderFilterLinkBuilder } from "@app/lib/adminSmartFolderLinks"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { acceptRemoveMemoryInsight, fetchAdminInsights, promoteInsightMemory, type AdminInsightSuggestion, type PaginationMeta } from "../api/insights"

const QUERY_KEY = ["admin", "insights"]

export function AdminInsightsRoute() {
  const { t } = useT("agent_insights")
  usePageTitle(t("admin_title"))
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const page = pageFromSearch(location.search)
  const queryKey = [...QUERY_KEY, location.search]

  const query = useQuery({
    queryKey,
    queryFn: () => fetchAdminInsights(location.search, page, 20),
    placeholderData: keepPreviousData
  })

  function navigateTo(params: URLSearchParams) {
    const search = params.toString()
    navigate(`${location.pathname}${search ? `?${search}` : ""}`)
  }

  function goToPage(nextPage: number) {
    const params = new URLSearchParams(location.search)
    params.set("page", String(nextPage))
    navigateTo(params)
  }

  return (
    <Page.Root aria-label={t("aria_admin_insights")} gutter="responsive" size="wide">
      <AdminInsightsHeader />

      {query.isPending ? <Notice>{t("loading")}</Notice> : null}
      {query.isError ? <Notice tone="danger">{errorMessage(query.error, t("load_error"))}</Notice> : null}
      {query.isSuccess ? (
        <AdminInsightsContent
          onNavigate={navigateTo}
          onPageChange={goToPage}
          onSmartFolderMutationSuccess={() => void queryClient.invalidateQueries({ queryKey: QUERY_KEY })}
          pathname={location.pathname}
          payload={query.data}
          prefix={routePrefix(location.pathname)}
          queryKey={queryKey}
          search={location.search}
        />
      ) : null}
    </Page.Root>
  )
}

function AdminInsightsHeader() {
  const { t } = useT("agent_insights")
  return (
    <Page.Header className="items-end border-b border-border pb-4">
      <Page.HeadingGroup>
        <Text as="p" muted variant="label">
          {t("admin:section_label")}
        </Text>
        <Page.Title className="mt-1">{t("admin_title")}</Page.Title>
        <Page.Description>{t("admin_subtitle")}</Page.Description>
      </Page.HeadingGroup>
    </Page.Header>
  )
}

function AdminInsightsContent({
  onNavigate,
  onPageChange,
  onSmartFolderMutationSuccess,
  pathname,
  payload,
  prefix,
  queryKey,
  search
}: {
  onNavigate: (params: URLSearchParams) => void
  onPageChange: (page: number) => void
  onSmartFolderMutationSuccess: () => void
  pathname: string
  payload: Awaited<ReturnType<typeof fetchAdminInsights>>
  prefix: string
  queryKey: unknown[]
  search: string
}) {
  const { t } = useT("agent_insights")
  const activeUserFolderId = payload.smart_folders.find((folder) => folder.id === payload.active_smart_folder_id && folder.kind === "user_defined")?.id

  return (
    <AdminFiltersLayout
      filterBar={
        <FilterBar
          filter={payload.filter}
          filterSchema={payload.filter_schema}
          buildLink={adminSmartFolderFilterLinkBuilder(activeUserFolderId)}
          pathname={pathname}
          search={search}
        />
      }
      smartFolders={
        <AdminSmartFolderNav
          activeFolderId={payload.active_smart_folder_id}
          ariaLabel={t("smart_folders_aria")}
          currentFilter={payload.filter}
          folders={payload.smart_folders}
          heading={t("smart_folders_heading")}
          onMutationSuccess={onSmartFolderMutationSuccess}
          prefix={prefix}
          queryKey={queryKey}
          subjectType="agent_insight"
        />
      }
    >
      <AdminInsightsTable
        meta={payload.meta}
        onNavigate={onNavigate}
        onPageChange={onPageChange}
        prefix={prefix}
        search={search}
        suggestions={payload.suggestions}
      />
    </AdminFiltersLayout>
  )
}

function AdminInsightsTable({
  meta,
  onNavigate,
  onPageChange,
  prefix,
  search,
  suggestions
}: {
  meta: PaginationMeta
  onNavigate: (params: URLSearchParams) => void
  onPageChange: (page: number) => void
  prefix: string
  search: string
  suggestions: AdminInsightSuggestion[]
}) {
  const { t } = useT("agent_insights")

  if (suggestions.length === 0) {
    return <AdminEventPanelMessage>{t("empty")}</AdminEventPanelMessage>
  }

  return (
    <AdminEventLogTable
      columns={adminInsightColumns(t, prefix)}
      defaultSort={{ column: "severity", direction: "desc" }}
      getRowKey={(suggestion) => suggestion.id}
      onNavigate={onNavigate}
      panel={adminInsightsPanel(t, meta, onPageChange, search)}
      renderExpanded={(suggestion) => <ExpandedSuggestion suggestion={suggestion} />}
      rows={suggestions}
      search={search}
      storageKey="syrus.admin.insights.visible_columns"
    />
  )
}

function adminInsightColumns(
  t: (key: string, options?: Record<string, unknown>) => string,
  prefix: string
): Array<AdminEventLogTableColumn<AdminInsightSuggestion>> {
  return [
    {
      key: "title",
      header: t("col_title"),
      required: true,
      sort: "title",
      className: "min-w-72",
      render: (suggestion, { expanded, toggleExpanded }) => (
        <div className="max-w-md">
          <button
            aria-expanded={expanded}
            className="text-left text-sm font-medium text-text-primary underline-offset-2 hover:underline"
            onClick={toggleExpanded}
            type="button"
          >
            {suggestion.title}
          </button>
          <div className="mt-1 flex flex-wrap gap-1.5">
            <TonePill tone="gray">{suggestion.category}</TonePill>
            <TonePill tone={suggestion.proposal_type === "remove_memory" ? "red" : "gray"}>{t(`proposal_${suggestion.proposal_type}`)}</TonePill>
          </div>
        </div>
      )
    },
    {
      key: "repository",
      header: t("col_repository"),
      sort: "repository",
      render: (suggestion) => (
        <Link
          className="text-brand-emphasis underline hover:no-underline dark:text-brand-emphasis"
          to={withRoutePrefix(suggestion.repository.insights_path, prefix)}
        >
          {suggestion.repository.slug}
        </Link>
      )
    },
    {
      key: "user",
      header: t("col_user"),
      sort: "user",
      className: "text-xs text-text-secondary",
      render: (suggestion) => suggestion.user.display_name
    },
    {
      key: "severity",
      header: t("col_severity"),
      sort: "severity",
      render: (suggestion) => <SeverityPill severity={suggestion.severity} />
    },
    {
      key: "confidence",
      header: t("col_confidence"),
      sort: "confidence",
      className: "text-xs text-text-secondary",
      render: (suggestion) => `${Math.round(suggestion.confidence * 100)}%`
    },
    {
      key: "state",
      header: t("col_state"),
      sort: "state",
      render: (suggestion) => <StatePill state={suggestion.state} />
    },
    {
      key: "created",
      header: t("col_created"),
      sort: "created",
      defaultVisible: false,
      className: "text-xs text-text-secondary",
      render: (suggestion) => <RelativeTimestamp value={suggestion.created_at} />
    },
    {
      key: "actions",
      header: t("col_actions"),
      label: t("col_actions"),
      pin: "end",
      required: true,
      className: "text-right",
      render: (suggestion) => <SuggestionActions prefix={prefix} suggestion={suggestion} />
    }
  ]
}

function adminInsightsPanel(
  t: (key: string, options?: Record<string, unknown>) => string,
  meta: PaginationMeta,
  onPageChange: (page: number) => void,
  search: string
): AdminDataTablePanelConfig {
  const firstItem = meta.total === 0 ? 0 : (meta.page - 1) * meta.per_page + 1
  const lastItem = Math.min(meta.page * meta.per_page, meta.total)

  return {
    summary: t("suggestions_heading"),
    meta: t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total }),
    pagination: {
      ariaLabel: t("pagination_aria"),
      label: t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total }),
      nextLabel: t("pagination_next"),
      onNavigate: (params) => onPageChange(Number(params.get("page") || meta.page)),
      pagination: {
        page: meta.page,
        has_next_page: meta.page < meta.total_pages,
        has_previous_page: meta.page > 1,
        next_page: meta.page < meta.total_pages ? meta.page + 1 : null,
        previous_page: meta.page > 1 ? meta.page - 1 : null,
        total_pages: meta.total_pages
      },
      previousLabel: t("pagination_previous"),
      search
    }
  }
}

function SuggestionActions({ suggestion, prefix }: { suggestion: AdminInsightSuggestion; prefix: string }) {
  const { t } = useT("agent_insights")
  const queryClient = useQueryClient()

  const promoteMutation = useMutation({
    mutationFn: () => promoteInsightMemory(suggestion.id),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: QUERY_KEY })
  })

  const acceptRemoveMemoryMutation = useMutation({
    mutationFn: () => acceptRemoveMemoryInsight(suggestion.id),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: QUERY_KEY })
  })

  return (
    <div className="flex flex-col items-end gap-1">
      <Toolbar className="justify-end">
        <Link className="text-xs text-brand-emphasis underline hover:no-underline dark:text-brand-emphasis" to={withRoutePrefix(suggestion.job_path, prefix)}>
          {t("view_job")}
        </Link>
        {suggestion.has_memory_suggestion ? (
          <Button disabled={promoteMutation.isPending} onClick={() => promoteMutation.mutate()} size="sm" variant="secondary">
            {promoteMutation.isPending ? t("promoting") : t("promote_to_instance")}
          </Button>
        ) : null}
        {suggestion.state === "pending" && suggestion.proposal_type === "remove_memory" ? (
          <Button disabled={acceptRemoveMemoryMutation.isPending} onClick={() => acceptRemoveMemoryMutation.mutate()} size="sm" variant="danger">
            {acceptRemoveMemoryMutation.isPending ? t("removing_memory") : t("accept_remove_memory")}
          </Button>
        ) : null}
      </Toolbar>
      {promoteMutation.isError ? (
        <Text role="alert" tone="danger" variant="caption">
          {errorMessage(promoteMutation.error, t("promote_error"))}
        </Text>
      ) : null}
      {acceptRemoveMemoryMutation.isError ? (
        <Text role="alert" tone="danger" variant="caption">
          {errorMessage(acceptRemoveMemoryMutation.error, t("remove_memory_error"))}
        </Text>
      ) : null}
    </div>
  )
}

function ExpandedSuggestion({ suggestion }: { suggestion: AdminInsightSuggestion }) {
  const { t } = useT("agent_insights")

  return (
    <div className="space-y-3">
      {suggestion.suggested_prompt ? <DetailPre label={t("suggested_prompt_label")} value={suggestion.suggested_prompt} /> : null}
      {suggestion.memory_suggestion ? <DetailPre label={t("memory_suggestion_label")} value={suggestion.memory_suggestion} /> : null}
      {suggestion.proposal_type === "remove_memory" ? <RemoveMemoryDetails suggestion={suggestion} /> : null}
      {suggestion.state === "retired" ? <RetiredDetails suggestion={suggestion} /> : null}
    </div>
  )
}

function DetailPre({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</p>
      <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-white p-3 text-xs text-gray-700 ring-1 ring-gray-200 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-700">
        {value}
      </pre>
    </div>
  )
}

function RemoveMemoryDetails({ suggestion }: { suggestion: AdminInsightSuggestion }) {
  const { t } = useT("agent_insights")
  return (
    <div className="rounded border border-red-200 bg-red-50 p-3 dark:border-red-900/50 dark:bg-red-950/20">
      <p className="text-xs font-medium uppercase text-red-700 dark:text-red-300">{t("remove_memory_label", { id: suggestion.target_memory_id })}</p>
      {suggestion.stale_memory_text ? (
        <pre className="mt-1 whitespace-pre-wrap rounded bg-white p-3 text-xs text-red-900 ring-1 ring-red-100 dark:bg-gray-950 dark:text-red-200 dark:ring-red-900/60">
          {suggestion.stale_memory_text}
        </pre>
      ) : null}
      {suggestion.stale_memory_evidence ? (
        <p className="mt-2 whitespace-pre-wrap text-xs text-red-800 dark:text-red-200">{suggestion.stale_memory_evidence}</p>
      ) : null}
    </div>
  )
}

function RetiredDetails({ suggestion }: { suggestion: AdminInsightSuggestion }) {
  const { t } = useT("agent_insights")
  return (
    <div className="rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
      <p className="font-medium text-gray-700 dark:text-gray-200">{t("retired_heading")}</p>
      {suggestion.retired_reason ? <p className="mt-1 whitespace-pre-wrap">{suggestion.retired_reason}</p> : null}
      {suggestion.superseded_by_insight_id ? <p className="mt-1">{t("superseded_by_insight_label", { id: suggestion.superseded_by_insight_id })}</p> : null}
      {suggestion.superseded_by_job_slug ? <p className="mt-1">{t("superseded_by_job_label", { slug: suggestion.superseded_by_job_slug })}</p> : null}
    </div>
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

function pageFromSearch(search: string) {
  const page = Number(new URLSearchParams(search).get("page") || "1")
  return Number.isFinite(page) && page > 0 ? page : 1
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default AdminInsightsRoute

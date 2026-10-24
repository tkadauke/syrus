import { useQuery } from "@tanstack/react-query"
import { useLocation, useNavigate } from "react-router-dom"
import {
  AdminEventFilterBar,
  AdminEventLogTable,
  AdminEventPageShell,
  AdminEventPanelMessage,
  type AdminEventLogTableColumn
} from "@app/components/AdminEventLogPanel"
import { fetchGithubApiUsage, type GithubApiUsageOperationRow, type GithubApiUsageRepositoryRow } from "../api/githubApiUsage"
import { Button } from "@app/components/Button"
import { buildFlatFilterLink } from "@app/lib/flatFilterLink"
import { useT } from "@app/hooks/useT"

const FILTER_FIELDS = [
  "hours",
  "operation",
  "resource",
  "auth_source",
  "credential_key",
  "repository_id",
  "repo_slug",
  "user_id",
  "installation_id",
  "status",
  "rate_limited",
  "bucket_since",
  "last_seen_since"
] as const

function number(value: number | null | undefined) {
  return typeof value === "number" ? value.toLocaleString() : "-"
}

function time(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export default function AdminGithubApiUsage() {
  const { t } = useT("github_source")
  const location = useLocation()
  const navigate = useNavigate()
  const search = location.search
  const query = useQuery({
    queryKey: ["admin", "github_api_usage", search],
    queryFn: () => fetchGithubApiUsage(search),
    refetchInterval: 60_000
  })
  const payload = query.data

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <Button disabled={query.isFetching} onClick={() => void query.refetch()} variant="secondary">
          {query.isFetching ? t("api_usage.refreshing") : t("api_usage.refresh")}
        </Button>
      }
      ariaLabel={t("api_usage.title")}
      description={t("api_usage.description")}
      eyebrow={t("api_usage.eyebrow")}
      title={t("api_usage.title")}
    >
      <AdminEventFilterBar
        buildLink={buildFlatFilterLink(FILTER_FIELDS)}
        filter={payload?.filter}
        filterSchema={payload?.filter_schema}
        fields={[
          {
            name: "hours",
            label: t("api_usage.filters.window"),
            defaultValue: "24",
            options: [
              { label: t("api_usage.filters.one_hour"), value: "1" },
              { label: t("api_usage.filters.six_hours"), value: "6" },
              { label: t("api_usage.filters.twenty_four_hours"), value: "24" },
              { label: t("api_usage.filters.three_days"), value: "72" },
              { label: t("api_usage.filters.seven_days"), value: "168" }
            ]
          },
          { name: "operation", label: t("api_usage.filters.operation"), placeholder: "pull_request" },
          { name: "resource", label: t("api_usage.filters.resource"), placeholder: "core" },
          { name: "auth_source", label: t("api_usage.filters.auth_source"), placeholder: "pat" },
          { name: "credential_key", label: t("api_usage.filters.credential_key"), placeholder: "user:1" },
          { name: "repository_id", label: t("api_usage.filters.repository_id"), inputMode: "numeric" },
          { name: "repo_slug", label: t("api_usage.filters.repository_slug"), placeholder: "owner/name" },
          { name: "user_id", label: t("api_usage.filters.user_id"), inputMode: "numeric" },
          { name: "installation_id", label: t("api_usage.filters.installation_id"), inputMode: "numeric" },
          { name: "status", label: t("api_usage.filters.last_status"), inputMode: "numeric" },
          { name: "rate_limited", label: t("api_usage.filters.rate_limited"), options: [{ label: t("api_usage.filters.yes"), value: "true" }] },
          { name: "bucket_since", label: t("api_usage.filters.bucket_since"), placeholder: "1h" },
          { name: "last_seen_since", label: t("api_usage.filters.last_seen_since"), placeholder: "1h" }
        ]}
        search={search}
        searchLabel={t("api_usage.filters.search")}
        clearLabel={t("api_usage.filters.clear")}
      />

      {query.isPending ? <AdminEventPanelMessage>{t("api_usage.loading")}</AdminEventPanelMessage> : null}
      {query.isError ? <AdminEventPanelMessage tone="error">{t("api_usage.load_error")}</AdminEventPanelMessage> : null}

      {payload ? (
        <div className="space-y-6">
          <section className="grid gap-4 md:grid-cols-3">
            <Metric label={t("api_usage.metrics.requests")} value={payload.totals.requests} />
            <Metric label={t("api_usage.metrics.rate_limited")} value={payload.totals.rate_limited} />
            <Metric label={t("api_usage.metrics.generated")} value={time(payload.generated_at)} />
          </section>

          {payload.recent_rate_limits.length ? (
            <UsageTable
              rows={payload.recent_rate_limits}
              storageKey="syrus.admin.github_api_usage.rate_limits.columns"
              summary={t("api_usage.tables.recent_rate_limits")}
              showRepo
            />
          ) : null}

          <UsageTable rows={payload.by_operation} storageKey="syrus.admin.github_api_usage.operations.columns" summary={t("api_usage.tables.by_operation")} />

          <RepositoryTable rows={payload.by_repository} />
        </div>
      ) : null}
    </AdminEventPageShell>
  )
}

function Metric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-950">
      <div className="text-sm font-medium text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-gray-950 dark:text-gray-50">{typeof value === "number" ? number(value) : value}</div>
    </div>
  )
}

function UsageTable({
  rows,
  showRepo = false,
  storageKey,
  summary
}: {
  rows: (GithubApiUsageOperationRow & { repo_slug?: string | null })[]
  showRepo?: boolean
  storageKey: string
  summary: string
}) {
  const { t } = useT("github_source")
  const columns: Array<AdminEventLogTableColumn<GithubApiUsageOperationRow & { repo_slug?: string | null }>> = [
    {
      key: "auth_source",
      header: t("api_usage.columns.credential"),
      required: true,
      sort: "auth_source",
      sortValue: (row) => row.auth_source,
      className: "font-mono text-xs",
      render: (row) => row.auth_source
    },
    {
      key: "credential_key",
      header: t("api_usage.columns.credential_key"),
      defaultVisible: false,
      sort: "credential_key",
      sortValue: (row) => row.credential_key || "",
      className: "font-mono text-xs",
      render: (row) => row.credential_key || "-"
    },
    ...(showRepo
      ? [
          {
            key: "repo_slug",
            header: t("api_usage.columns.repository"),
            sort: "repo_slug",
            sortValue: (row) => row.repo_slug || "",
            className: "font-mono text-xs",
            render: (row) => row.repo_slug || "-"
          } satisfies AdminEventLogTableColumn<GithubApiUsageOperationRow & { repo_slug?: string | null }>
        ]
      : []),
    { key: "operation", header: t("api_usage.columns.operation"), sort: "operation", sortValue: (row) => row.operation, render: (row) => row.operation },
    { key: "resource", header: t("api_usage.columns.resource"), sort: "resource", sortValue: (row) => row.resource, render: (row) => row.resource },
    { key: "requests", header: t("api_usage.columns.requests"), sort: "requests", sortValue: (row) => row.requests, render: (row) => number(row.requests) },
    {
      key: "rate_limited",
      header: t("api_usage.columns.limited"),
      sort: "rate_limited",
      sortValue: (row) => row.rate_limited,
      render: (row) => number(row.rate_limited)
    },
    {
      key: "last_status",
      header: t("api_usage.columns.last_status"),
      defaultVisible: false,
      sort: "last_status",
      sortValue: (row) => row.last_status ?? 0,
      render: (row) => number(row.last_status)
    },
    {
      key: "last_limit",
      header: t("api_usage.columns.limit"),
      defaultVisible: false,
      sort: "last_limit",
      sortValue: (row) => row.last_limit ?? 0,
      render: (row) => number(row.last_limit)
    },
    {
      key: "min_remaining",
      header: t("api_usage.columns.min_remaining"),
      sort: "min_remaining",
      sortValue: (row) => row.min_remaining,
      render: (row) => number(row.min_remaining)
    },
    {
      key: "last_reset_at",
      header: t("api_usage.columns.reset"),
      defaultVisible: false,
      sort: "last_reset_at",
      sortValue: (row) => row.last_reset_at || "",
      render: (row) => time(row.last_reset_at)
    },
    {
      key: "bucket_started_at",
      header: t("api_usage.columns.bucket"),
      defaultVisible: false,
      sort: "bucket_started_at",
      sortValue: (row) => row.bucket_started_at || "",
      render: (row) => time(row.bucket_started_at)
    },
    {
      key: "last_seen_at",
      header: t("api_usage.columns.last_seen"),
      sort: "last_seen_at",
      sortValue: (row) => row.last_seen_at || "",
      render: (row) => time(row.last_seen_at)
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      defaultSort={{ column: "requests", direction: "desc" }}
      getRowKey={(row) => `${row.auth_source}-${row.operation}-${row.resource}-${row.repo_slug ?? ""}`}
      localSort
      panel={{ summary, meta: t("api_usage.tables.row_count", { count: rows.length }) }}
      rows={rows}
      storageKey={storageKey}
    />
  )
}

function RepositoryTable({ rows }: { rows: GithubApiUsageRepositoryRow[] }) {
  const { t } = useT("github_source")
  const columns: Array<AdminEventLogTableColumn<GithubApiUsageRepositoryRow>> = [
    {
      key: "repo_slug",
      header: t("api_usage.columns.repository"),
      required: true,
      sort: "repo_slug",
      sortValue: (row) => row.repo_slug,
      render: (row) => row.repo_slug
    },
    {
      key: "auth_source",
      header: t("api_usage.columns.credential"),
      sort: "auth_source",
      sortValue: (row) => row.auth_source,
      className: "font-mono text-xs",
      render: (row) => row.auth_source
    },
    {
      key: "credential_key",
      header: t("api_usage.columns.credential_key"),
      defaultVisible: false,
      sort: "credential_key",
      sortValue: (row) => row.credential_key || "",
      className: "font-mono text-xs",
      render: (row) => row.credential_key || "-"
    },
    { key: "requests", header: t("api_usage.columns.requests"), sort: "requests", sortValue: (row) => row.requests, render: (row) => number(row.requests) },
    {
      key: "rate_limited",
      header: t("api_usage.columns.limited"),
      sort: "rate_limited",
      sortValue: (row) => row.rate_limited,
      render: (row) => number(row.rate_limited)
    },
    {
      key: "last_status",
      header: t("api_usage.columns.last_status"),
      defaultVisible: false,
      sort: "last_status",
      sortValue: (row) => row.last_status ?? 0,
      render: (row) => number(row.last_status)
    },
    {
      key: "last_limit",
      header: t("api_usage.columns.limit"),
      defaultVisible: false,
      sort: "last_limit",
      sortValue: (row) => row.last_limit ?? 0,
      render: (row) => number(row.last_limit)
    },
    {
      key: "min_remaining",
      header: t("api_usage.columns.min_remaining"),
      sort: "min_remaining",
      sortValue: (row) => row.min_remaining,
      render: (row) => number(row.min_remaining)
    },
    {
      key: "last_reset_at",
      header: t("api_usage.columns.reset"),
      defaultVisible: false,
      sort: "last_reset_at",
      sortValue: (row) => row.last_reset_at || "",
      render: (row) => time(row.last_reset_at)
    },
    {
      key: "last_seen_at",
      header: t("api_usage.columns.last_seen"),
      sort: "last_seen_at",
      sortValue: (row) => row.last_seen_at || "",
      render: (row) => time(row.last_seen_at)
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      defaultSort={{ column: "requests", direction: "desc" }}
      getRowKey={(row) => `${row.auth_source}-${row.repo_slug}`}
      localSort
      panel={{ summary: t("api_usage.tables.by_repository"), meta: t("api_usage.tables.row_count", { count: rows.length }) }}
      rows={rows}
      storageKey="syrus.admin.github_api_usage.repositories.columns"
    />
  )
}

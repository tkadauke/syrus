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

function number(value: number | null | undefined) {
  return typeof value === "number" ? value.toLocaleString() : "-"
}

function time(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export default function AdminGithubApiUsage() {
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
      actions={<Button disabled={query.isFetching} onClick={() => void query.refetch()} variant="secondary">{query.isFetching ? "Refreshing..." : "Refresh"}</Button>}
      ariaLabel="GitHub API Usage"
      description="Hourly rollups by credential, operation, repository, and rate-limit resource."
      eyebrow="Admin"
      title="GitHub API Usage"
    >
      <AdminEventFilterBar
        buildLink={buildFlatFilterLink(["hours"])}
        filter={payload?.filter}
        filterSchema={payload?.filter_schema}
        fields={[
          {
            name: "hours",
            label: "Window",
            defaultValue: "24",
            options: [
              { label: "1 hour", value: "1" },
              { label: "6 hours", value: "6" },
              { label: "24 hours", value: "24" },
              { label: "3 days", value: "72" },
              { label: "7 days", value: "168" }
            ]
          }
        ]}
        search={search}
        searchLabel="Search"
        clearLabel="Clear"
      />

      {query.isPending ? <AdminEventPanelMessage>Loading...</AdminEventPanelMessage> : null}
      {query.isError ? <AdminEventPanelMessage tone="error">Could not load GitHub API usage.</AdminEventPanelMessage> : null}

      {payload ? (
        <div className="space-y-6">
          <section className="grid gap-4 md:grid-cols-3">
            <Metric label="Requests" value={payload.totals.requests} />
            <Metric label="Rate limited" value={payload.totals.rate_limited} />
            <Metric label="Generated" value={time(payload.generated_at)} />
          </section>

          {payload.recent_rate_limits.length ? <UsageTable rows={payload.recent_rate_limits} storageKey="syrus.admin.github_api_usage.rate_limits.columns" summary="Recent Rate Limits" showRepo /> : null}

          <UsageTable rows={payload.by_operation} storageKey="syrus.admin.github_api_usage.operations.columns" summary="By Operation" />

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

function UsageTable({ rows, showRepo = false, storageKey, summary }: { rows: (GithubApiUsageOperationRow & { repo_slug?: string | null })[]; showRepo?: boolean; storageKey: string; summary: string }) {
  const columns: Array<AdminEventLogTableColumn<GithubApiUsageOperationRow & { repo_slug?: string | null }>> = [
    { key: "auth_source", header: "Credential", required: true, sort: "auth_source", sortValue: (row) => row.auth_source, className: "font-mono text-xs", render: (row) => row.auth_source },
    ...(showRepo ? [{ key: "repo_slug", header: "Repository", sort: "repo_slug", sortValue: (row) => row.repo_slug || "", className: "font-mono text-xs", render: (row) => row.repo_slug || "-" } satisfies AdminEventLogTableColumn<GithubApiUsageOperationRow & { repo_slug?: string | null }>] : []),
    { key: "operation", header: "Operation", sort: "operation", sortValue: (row) => row.operation, render: (row) => row.operation },
    { key: "resource", header: "Resource", sort: "resource", sortValue: (row) => row.resource, render: (row) => row.resource },
    { key: "requests", header: "Requests", sort: "requests", sortValue: (row) => row.requests, render: (row) => number(row.requests) },
    { key: "rate_limited", header: "Limited", sort: "rate_limited", sortValue: (row) => row.rate_limited, render: (row) => number(row.rate_limited) },
    { key: "min_remaining", header: "Min remaining", sort: "min_remaining", sortValue: (row) => row.min_remaining, render: (row) => number(row.min_remaining) },
    { key: "last_seen_at", header: "Last seen", sort: "last_seen_at", sortValue: (row) => row.last_seen_at || "", render: (row) => time(row.last_seen_at) }
  ]

  return <AdminEventLogTable columns={columns} defaultSort={{ column: "requests", direction: "desc" }} getRowKey={(row) => `${row.auth_source}-${row.operation}-${row.resource}-${row.repo_slug ?? ""}`} localSort panel={{ summary, meta: `${rows.length} rows` }} rows={rows} storageKey={storageKey} />
}

function RepositoryTable({ rows }: { rows: GithubApiUsageRepositoryRow[] }) {
  const columns: Array<AdminEventLogTableColumn<GithubApiUsageRepositoryRow>> = [
    { key: "repo_slug", header: "Repository", required: true, sort: "repo_slug", sortValue: (row) => row.repo_slug, render: (row) => row.repo_slug },
    { key: "auth_source", header: "Credential", sort: "auth_source", sortValue: (row) => row.auth_source, className: "font-mono text-xs", render: (row) => row.auth_source },
    { key: "requests", header: "Requests", sort: "requests", sortValue: (row) => row.requests, render: (row) => number(row.requests) },
    { key: "rate_limited", header: "Limited", sort: "rate_limited", sortValue: (row) => row.rate_limited, render: (row) => number(row.rate_limited) },
    { key: "min_remaining", header: "Min remaining", sort: "min_remaining", sortValue: (row) => row.min_remaining, render: (row) => number(row.min_remaining) },
    { key: "last_seen_at", header: "Last seen", sort: "last_seen_at", sortValue: (row) => row.last_seen_at || "", render: (row) => time(row.last_seen_at) }
  ]

  return <AdminEventLogTable columns={columns} defaultSort={{ column: "requests", direction: "desc" }} getRowKey={(row) => `${row.auth_source}-${row.repo_slug}`} localSort panel={{ summary: "By Repository", meta: `${rows.length} rows` }} rows={rows} storageKey="syrus.admin.github_api_usage.repositories.columns" />
}

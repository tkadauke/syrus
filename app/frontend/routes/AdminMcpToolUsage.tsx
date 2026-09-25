import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { SectionHeading } from "../components/Heading"
import { Link, useLocation } from "react-router-dom"
import {
  fetchAdminMcpToolUsage,
  type McpStartupPhaseLatencyRow,
  type McpStartupTimingSection as McpStartupTimingSectionType,
  type McpToolUsageBreakdownRow,
  type McpToolCardGapRow,
  type McpToolUsagePayload,
  type McpToolUsageRecentCall,
  type McpToolUsageToolRow
} from "../api/adminMcpToolUsage"
import {
  AdminEventFilterBar,
  AdminEventLogTable,
  type AdminEventLogTableColumn,
  AdminEventPageShell,
  AdminEventPanelMessage,
  formatEventDate
} from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { DataTable, PanelMessage, Section, Text } from "../components/ui"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { buildFlatFilterLink } from "../lib/flatFilterLink"

const WINDOW_PRESETS = [
  { value: "24h", hours: 24 },
  { value: "7d", hours: 24 * 7 },
  { value: "30d", hours: 24 * 30 },
  { value: "90d", hours: 24 * 90 }
] as const

const SURFACES = ["all", "workflow", "chat"] as const

export function AdminMcpToolUsage() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_mcp_tool_usage"))
  const location = useLocation()
  const search = location.search
  const usage = useQuery({
    queryKey: ["admin", "mcp_tool_usage", search],
    queryFn: () => fetchAdminMcpToolUsage(search),
    placeholderData: keepPreviousData
  })

  return (
    <AdminEventPageShell
      actions={
        <Button
          className="w-fit"
          disabled={usage.isFetching}
          onClick={() => void usage.refetch()}
          variant="secondary"
        >
          {usage.isFetching ? t("mcp_tool_usage.refreshing") : t("mcp_tool_usage.refresh")}
        </Button>
      }
      ariaLabel={t("mcp_tool_usage.aria")}
      eyebrow={t("section_label")}
      title={t("mcp_tool_usage.heading")}
    >
      <McpToolUsageFilters search={search} />
      {usage.isPending ? <AdminEventPanelMessage>{t("mcp_tool_usage.loading")}</AdminEventPanelMessage> : null}
      {usage.isError ? <AdminEventPanelMessage tone="error">{errorMessage(usage.error, t("mcp_tool_usage.error_load"))}</AdminEventPanelMessage> : null}
      {usage.isSuccess ? <McpToolUsageView payload={usage.data} /> : null}
    </AdminEventPageShell>
  )
}

function McpToolUsageFilters({ search }: { search: string }) {
  const { t } = useT("admin")
  const params = new URLSearchParams(search)
  const filter = {
    and: [
      { field: "window_preset", op: "is", value: params.get("window_preset") || "7d" },
      ...(params.get("surface") ? [{ field: "surface", op: "is", value: params.get("surface") || "all" }] : []),
      ...(params.get("tool_name") ? [{ field: "tool_name", op: "is", value: params.get("tool_name") || "" }] : []),
      ...(params.get("server_name") ? [{ field: "server_name", op: "is", value: params.get("server_name") || "" }] : [])
    ]
  }
  const filterLink = buildFlatFilterLink(["window_preset", "surface", "tool_name", "server_name"], (next) => {
    const preset = WINDOW_PRESETS.find((entry) => entry.value === next.get("window_preset"))
    if (preset) {
      next.set("since", new Date(Date.now() - preset.hours * 60 * 60 * 1000).toISOString())
      next.delete("until")
    } else {
      next.delete("since")
    }
    if (next.get("surface") === "all") next.delete("surface")
  })

  return (
    <AdminEventFilterBar
      buildLink={filterLink}
      clearLabel={t("clear_filters")}
      fields={[
        { name: "window_preset", label: t("mcp_tool_usage.window_label"), options: WINDOW_PRESETS.map((preset) => ({ label: t(`mcp_tool_usage.window_${preset.value}`), value: preset.value })) },
        { name: "surface", label: t("mcp_tool_usage.surface_label"), options: SURFACES.map((value) => ({ label: t(`mcp_tool_usage.surface_${value}`), value })) },
        { name: "tool_name", label: t("mcp_tool_usage.tool_label"), placeholder: t("mcp_tool_usage.tool_placeholder") },
        { name: "server_name", label: t("mcp_tool_usage.server_label"), placeholder: t("mcp_tool_usage.server_placeholder") }
      ]}
      filter={filter}
      search={search}
      searchLabel={t("search")}
    />
  )
}

function McpToolUsageView({ payload }: { payload: McpToolUsagePayload }) {
  const { t } = useT("admin")
  const errorRate = payload.totals.calls > 0 ? Math.round((payload.totals.errors / payload.totals.calls) * 1000) / 10 : 0

  return (
    <div className="space-y-6">
      <section className="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatTile label={t("mcp_tool_usage.totals_calls")} value={payload.totals.calls} />
        <StatTile label={t("mcp_tool_usage.totals_errors")} value={payload.totals.errors} />
        <StatTile label={t("mcp_tool_usage.totals_error_rate")} value={`${errorRate}%`} />
      </section>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <ToolRowsPanel heading={t("mcp_tool_usage.top_tools_heading")} rows={payload.top_tools} />
        <ToolRowsPanel heading={t("mcp_tool_usage.error_rates_heading")} rows={payload.error_rates} />
      </div>

      <UnusedToolsPanel tools={payload.unused_advertised_tools} />

      <CardGapRankingPanel rows={payload.custom_card_gaps.ranked_gaps || []} />

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <BreakdownPanel heading={t("mcp_tool_usage.surface_breakdown_heading")} labelKey="surface" rows={payload.surface_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.provider_breakdown_heading")} labelKey="provider" rows={payload.provider_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.server_breakdown_heading")} labelKey="server_name" rows={payload.server_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.sidecar_mode_breakdown_heading")} labelKey="sidecar_mode" rows={payload.sidecar_mode_breakdown} />
      </div>

      <StartupTimingPanel section={payload.startup_timing} />

      <RecentCallsPanel calls={payload.recent_calls} />
    </div>
  )
}

function formatPhaseName(phase: string) {
  return phase.replaceAll("_", " ")
}

function formatMs(value: number | null) {
  return value == null ? "-" : `${Math.round(value)} ms`
}

// Left off the shared column-config primitive: this is a fixed set of ~5
// internal startup phases with all-numeric latency columns -- a technical
// diagnostic snapshot, not a record list with optional application columns
// an operator would want to declutter or reorder.
function StartupTimingPanel({ section }: { section: McpStartupTimingSectionType }) {
  const { t } = useT("admin")
  return (
    <Section.Root divided padding="none">
      <Section.Header className="px-4 py-3">
        <Section.Title>{t("mcp_tool_usage.startup_timing_heading")}</Section.Title>
        <Section.Actions>
          <Text as="span" variant="caption" muted>
            {t("mcp_tool_usage.startup_timing_turns_observed")}: {section.turns_observed}
          </Text>
          <Text as="span" tone={section.stalled_turns > 0 ? "danger" : "muted"} variant="caption">
            {t("mcp_tool_usage.startup_timing_stalled_turns")}: {section.stalled_turns}
          </Text>
        </Section.Actions>
      </Section.Header>
      {section.phase_latency.length === 0 ? <PanelMessage>{t("mcp_tool_usage.startup_timing_empty")}</PanelMessage> : (
        <DataTable.Root>
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_phase")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_count")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_avg")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_p50")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_p95")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.startup_timing_col_max")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {section.phase_latency.map((row: McpStartupPhaseLatencyRow) => (
              <DataTable.Row key={row.phase}>
                <DataTable.Cell className="font-medium capitalize">{formatPhaseName(row.phase)}</DataTable.Cell>
                <DataTable.Cell>{row.count}</DataTable.Cell>
                <DataTable.Cell>{formatMs(row.avg_ms)}</DataTable.Cell>
                <DataTable.Cell>{formatMs(row.p50_ms)}</DataTable.Cell>
                <DataTable.Cell>{formatMs(row.p95_ms)}</DataTable.Cell>
                <DataTable.Cell>{formatMs(row.max_ms)}</DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </Section.Root>
  )
}

function StatTile({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <div className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{value}</div>
    </div>
  )
}

// Left off the shared column-config primitive, like BreakdownPanel below:
// a compact 4-column leaderboard (tool + three numeric stats) with no
// optional columns worth hiding.
function ToolRowsPanel({ heading, rows }: { heading: string; rows: McpToolUsageToolRow[] }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading className="border-b border-gray-200 px-4 py-3 dark:border-gray-700">{heading}</SectionHeading>
      {rows.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.empty")}</AdminEventPanelMessage> : (
        <DataTable.Root wrapperClassName="rounded-none border-0">
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_tool")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_calls")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_errors")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_error_rate")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {rows.map((row) => (
              <DataTable.Row key={`${row.server_name || "-"}.${row.tool_name}`}>
                <DataTable.Cell className="align-top">
                  <div className="font-medium text-gray-900 dark:text-gray-100">{row.tool_name}</div>
                  <div className="text-xs text-gray-500 dark:text-gray-400">{row.server_name || "-"}</div>
                </DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{row.calls}</DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{row.errors}</DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{Math.round(row.error_rate * 1000) / 10}%</DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </section>
  )
}

function UnusedToolsPanel({ tools }: { tools: string[] }) {
  const { t } = useT("admin")
  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading>{t("mcp_tool_usage.unused_tools_heading")}</SectionHeading>
      {tools.length === 0 ? (
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{t("mcp_tool_usage.unused_tools_empty")}</p>
      ) : (
        <ul className="mt-3 flex flex-wrap gap-2">
          {tools.map((tool) => (
            <li className="rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950/60 dark:text-amber-200" key={tool}>{tool}</li>
          ))}
        </ul>
      )}
    </section>
  )
}

// Left off the shared column-config primitive: a compact 4-column
// aggregation table (grouping key + three numeric stats) with no optional
// columns worth hiding -- see ToolRowsPanel above.
function BreakdownPanel({ heading, labelKey, rows }: { heading: string; labelKey: "surface" | "provider" | "server_name" | "sidecar_mode"; rows: McpToolUsageBreakdownRow[] }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <SectionHeading className="border-b border-gray-200 px-4 py-3 dark:border-gray-700">{heading}</SectionHeading>
      {rows.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.empty")}</AdminEventPanelMessage> : (
        <DataTable.Root wrapperClassName="rounded-none border-0">
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell>{heading}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_calls")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_errors")}</DataTable.HeadCell>
              <DataTable.HeadCell>{t("mcp_tool_usage.col_error_rate")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {rows.map((row) => (
              <DataTable.Row key={String(row[labelKey] ?? "unknown")}>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{row[labelKey] || t("mcp_tool_usage.unknown")}</DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{row.calls}</DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{row.errors}</DataTable.Cell>
                <DataTable.Cell className="align-top text-gray-700 dark:text-gray-200">{Math.round(row.error_rate * 1000) / 10}%</DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      )}
    </section>
  )
}

function formatBytes(value: number | undefined) {
  if (value == null) return "-"
  if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`
  if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${value} B`
}

function formatRecommendation(value: string | undefined) {
  return value ? value.replaceAll("_", " ") : "-"
}

function buildCardGapRankingColumns(t: (key: string) => string): Array<AdminEventLogTableColumn<McpToolCardGapRow>> {
  return [
    {
      key: "tool",
      header: t("mcp_tool_usage.col_tool"),
      required: true,
      sort: "tool",
      sortValue: (row) => row.tool_name,
      render: (row) => (
        <>
          <div className="font-medium text-gray-900 dark:text-gray-100">{row.tool_name}</div>
          <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{row.card_status}</div>
          {row.server_names && row.server_names.length > 0 ? <div className="mt-1 break-words text-xs text-gray-500 dark:text-gray-400">{row.server_names.join(", ")}</div> : null}
        </>
      )
    },
    { key: "calls", header: t("mcp_tool_usage.col_calls"), sort: "calls", sortValue: (row) => row.calls ?? 0, className: "align-top font-mono text-xs text-gray-700 dark:text-gray-200", render: (row) => row.calls ?? 0 },
    { key: "errors", header: t("mcp_tool_usage.col_errors"), sort: "errors", sortValue: (row) => row.errors ?? 0, className: "align-top font-mono text-xs text-gray-700 dark:text-gray-200", render: (row) => row.errors ?? 0 },
    { key: "result_bytes", header: t("mcp_tool_usage.col_result_bytes"), sort: "result_bytes", sortValue: (row) => row.result_bytes ?? 0, className: "align-top font-mono text-xs text-gray-700 dark:text-gray-200", render: (row) => formatBytes(row.result_bytes) },
    {
      key: "owner",
      header: t("mcp_tool_usage.col_owner"),
      sort: "owner",
      sortValue: (row) => `${row.owner_type}.${row.owner_name}`,
      className: "align-top text-xs text-gray-700 dark:text-gray-200",
      render: (row) => (
        <>
          <div>{row.owner_type === "plugin" ? row.owner_name : t("mcp_tool_usage.owner_core")}</div>
          <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">{row.recommendation_target}</div>
        </>
      )
    },
    { key: "last_used", header: t("mcp_tool_usage.col_last_used"), sort: "last_used", sortValue: (row) => row.last_used_at || "", className: "align-top font-mono text-xs text-gray-700 dark:text-gray-200", render: (row) => row.last_used_at ? formatEventDate(row.last_used_at) : t("mcp_tool_usage.never_used") },
    { key: "recommendation", header: t("mcp_tool_usage.col_recommendation"), sort: "recommendation", sortValue: (row) => row.recommendation || "", className: "align-top text-xs text-gray-700 dark:text-gray-200", render: (row) => formatRecommendation(row.recommendation) }
  ]
}

function CardGapRankingPanel({ rows }: { rows: McpToolCardGapRow[] }) {
  const { t } = useT("admin")
  const columns = buildCardGapRankingColumns(t)

  return (
    rows.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.card_gap_ranking_empty")}</AdminEventPanelMessage> : (
      <AdminEventLogTable
        columns={columns}
        defaultSort={{ column: "calls", direction: "desc" }}
        getRowKey={(row) => `${row.card_status}.${row.tool_name}`}
        localSort
        panel={{ summary: t("mcp_tool_usage.card_gap_ranking_heading"), meta: `${rows.length} tools` }}
        rows={rows}
        storageKey="syrus.admin.mcp_tool_usage.card_gap_ranking.visible_columns"
      />
    )
  )
}

function RecentCallsPanel({ calls }: { calls: McpToolUsageRecentCall[] }) {
  const { t } = useT("admin")
  const columns: Array<AdminEventLogTableColumn<McpToolUsageRecentCall>> = [
    {
      className: "w-40 whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "w-40 px-4 py-2",
      header: t("mcp_tool_usage.col_time"),
      key: "time",
      sort: "time",
      sortValue: (row) => row.occurred_at,
      render: (row) => formatEventDate(row.occurred_at)
    },
    {
      className: "px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "px-4 py-2",
      header: t("mcp_tool_usage.col_call"),
      key: "call",
      sort: "call",
      sortValue: (row) => row.tool_name,
      render: (row) => (
        <>
          <div className="font-medium text-gray-900 dark:text-gray-100">{row.tool_name}</div>
          <div className="mt-1 text-gray-500 dark:text-gray-400">{row.server_name || "-"} · {row.surface} · {row.provider || t("mcp_tool_usage.unknown")}</div>
        </>
      )
    },
    {
      className: "px-4 py-3 align-top text-xs",
      headerClassName: "px-4 py-2",
      header: t("mcp_tool_usage.col_status"),
      key: "status",
      sort: "status",
      sortValue: (row) => row.status,
      render: (row) => (
        <>
          <span className={`rounded px-2 py-0.5 font-medium ${row.error ? "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-300" : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"}`}>{row.status}</span>
          {row.error_message_summary ? <div className="mt-1 max-w-xs break-words text-gray-500 dark:text-gray-400">{row.error_class ? `${row.error_class}: ` : ""}{row.error_message_summary}</div> : null}
        </>
      )
    },
    {
      className: "px-4 py-3 align-top text-xs",
      headerClassName: "px-4 py-2",
      header: t("mcp_tool_usage.col_links"),
      key: "links",
      render: (row) => (
        <div className="flex flex-col gap-1">
          {row.job_path ? <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={row.job_path}>{t("mcp_tool_usage.link_job", { id: row.job_id })}</Link> : null}
          {row.workflow_path ? <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={row.workflow_path}>{t("mcp_tool_usage.link_workflow", { id: row.workflow_id })}</Link> : null}
          {row.run_path ? <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={row.run_path}>{t("mcp_tool_usage.link_run", { id: row.run_id })}</Link> : null}
          {row.chat_path ? <Link className="text-brand underline hover:no-underline dark:text-brand-emphasis" to={row.chat_path}>{t("mcp_tool_usage.link_chat")}</Link> : null}
        </div>
      )
    }
  ]

  return (
    calls.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.recent_calls_empty")}</AdminEventPanelMessage> : (
      <AdminEventLogTable
        columns={columns}
        defaultSort={{ column: "time", direction: "desc" }}
        getRowKey={(row) => row.id}
        localSort
        panel={{ summary: t("mcp_tool_usage.recent_calls_heading"), meta: `${calls.length} calls` }}
        rows={calls}
        storageKey="syrus.admin.mcp_tool_usage.recent_calls.visible_columns"
      />
    )
  )
}

export default AdminMcpToolUsage

import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import {
  fetchAdminMcpToolUsage,
  type McpToolUsageBreakdownRow,
  type McpToolUsagePayload,
  type McpToolUsageRecentCall,
  type McpToolUsageToolRow
} from "../api/adminMcpToolUsage"
import {
  AdminEventLogTable,
  type AdminEventLogTableColumn,
  AdminEventPageShell,
  AdminEventPanelMessage,
  compactInputClass,
  formatEventDate
} from "../components/AdminEventLogPanel"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

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
  const navigate = useNavigate()
  const search = location.search
  const usage = useQuery({
    queryKey: ["admin", "mcp_tool_usage", search],
    queryFn: () => fetchAdminMcpToolUsage(search),
    placeholderData: keepPreviousData
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <button
          className="inline-flex w-fit items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
          disabled={usage.isFetching}
          onClick={() => void usage.refetch()}
          type="button"
        >
          {usage.isFetching ? t("mcp_tool_usage.refreshing") : t("mcp_tool_usage.refresh")}
        </button>
      }
      ariaLabel={t("mcp_tool_usage.aria")}
      eyebrow={t("section_label")}
      title={t("mcp_tool_usage.heading")}
    >
      <McpToolUsageFilters search={search} onNavigate={navigateSearch} />
      {usage.isPending ? <AdminEventPanelMessage>{t("mcp_tool_usage.loading")}</AdminEventPanelMessage> : null}
      {usage.isError ? <AdminEventPanelMessage tone="error">{errorMessage(usage.error, t("mcp_tool_usage.error_load"))}</AdminEventPanelMessage> : null}
      {usage.isSuccess ? <McpToolUsageView payload={usage.data} /> : null}
    </AdminEventPageShell>
  )
}

function McpToolUsageFilters({ onNavigate, search }: { onNavigate: (params: URLSearchParams) => void; search: string }) {
  const { t } = useT("admin")
  const params = new URLSearchParams(search)
  const activeSurface = params.get("surface") || "all"
  const activeWindow = params.get("window_preset") || "7d"
  const activeToolName = params.get("tool_name") || ""
  const activeServerName = params.get("server_name") || ""

  function setWindow(value: string) {
    const preset = WINDOW_PRESETS.find((entry) => entry.value === value)
    const next = new URLSearchParams(search)
    if (!preset) {
      next.delete("window_preset")
      next.delete("since")
      onNavigate(next)
      return
    }
    next.set("window_preset", preset.value)
    next.set("since", new Date(Date.now() - preset.hours * 60 * 60 * 1000).toISOString())
    next.delete("until")
    onNavigate(next)
  }

  function setSurface(value: string) {
    const next = new URLSearchParams(search)
    if (value === "all") {
      next.delete("surface")
    } else {
      next.set("surface", value)
    }
    onNavigate(next)
  }

  function setTextFilter(key: "tool_name" | "server_name", value: string) {
    const next = new URLSearchParams(search)
    const trimmed = value.trim()
    if (trimmed) {
      next.set(key, trimmed)
    } else {
      next.delete(key)
    }
    onNavigate(next)
  }

  return (
    <section className="flex flex-wrap items-end gap-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <label className="space-y-1">
        <span className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mcp_tool_usage.window_label")}</span>
        <select className={compactInputClass()} value={activeWindow} onChange={(event) => setWindow(event.target.value)}>
          {WINDOW_PRESETS.map((preset) => (
            <option key={preset.value} value={preset.value}>{t(`mcp_tool_usage.window_${preset.value}`)}</option>
          ))}
        </select>
      </label>
      <label className="space-y-1">
        <span className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mcp_tool_usage.surface_label")}</span>
        <select className={compactInputClass()} value={activeSurface} onChange={(event) => setSurface(event.target.value)}>
          {SURFACES.map((value) => (
            <option key={value} value={value}>{t(`mcp_tool_usage.surface_${value}`)}</option>
          ))}
        </select>
      </label>
      <label className="space-y-1">
        <span className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mcp_tool_usage.tool_label")}</span>
        <input
          className={compactInputClass()}
          onBlur={(event) => setTextFilter("tool_name", event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") setTextFilter("tool_name", event.currentTarget.value)
          }}
          placeholder={t("mcp_tool_usage.tool_placeholder")}
          type="text"
          defaultValue={activeToolName}
        />
      </label>
      <label className="space-y-1">
        <span className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("mcp_tool_usage.server_label")}</span>
        <input
          className={compactInputClass()}
          onBlur={(event) => setTextFilter("server_name", event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") setTextFilter("server_name", event.currentTarget.value)
          }}
          placeholder={t("mcp_tool_usage.server_placeholder")}
          type="text"
          defaultValue={activeServerName}
        />
      </label>
    </section>
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

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <BreakdownPanel heading={t("mcp_tool_usage.surface_breakdown_heading")} labelKey="surface" rows={payload.surface_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.provider_breakdown_heading")} labelKey="provider" rows={payload.provider_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.server_breakdown_heading")} labelKey="server_name" rows={payload.server_breakdown} />
        <BreakdownPanel heading={t("mcp_tool_usage.sidecar_mode_breakdown_heading")} labelKey="sidecar_mode" rows={payload.sidecar_mode_breakdown} />
      </div>

      <RecentCallsPanel calls={payload.recent_calls} />
    </div>
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

function ToolRowsPanel({ heading, rows }: { heading: string; rows: McpToolUsageToolRow[] }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <h2 className="border-b border-gray-200 px-4 py-3 text-sm font-semibold text-gray-900 dark:border-gray-700 dark:text-gray-100">{heading}</h2>
      {rows.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.empty")}</AdminEventPanelMessage> : (
        <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_tool")}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_calls")}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_errors")}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_error_rate")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {rows.map((row) => (
              <tr key={`${row.server_name || "-"}.${row.tool_name}`}>
                <td className="px-4 py-2 align-top">
                  <div className="font-medium text-gray-900 dark:text-gray-100">{row.tool_name}</div>
                  <div className="text-xs text-gray-500 dark:text-gray-400">{row.server_name || "-"}</div>
                </td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{row.calls}</td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{row.errors}</td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{Math.round(row.error_rate * 1000) / 10}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function UnusedToolsPanel({ tools }: { tools: string[] }) {
  const { t } = useT("admin")
  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("mcp_tool_usage.unused_tools_heading")}</h2>
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

function BreakdownPanel({ heading, labelKey, rows }: { heading: string; labelKey: "surface" | "provider" | "server_name" | "sidecar_mode"; rows: McpToolUsageBreakdownRow[] }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <h2 className="border-b border-gray-200 px-4 py-3 text-sm font-semibold text-gray-900 dark:border-gray-700 dark:text-gray-100">{heading}</h2>
      {rows.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.empty")}</AdminEventPanelMessage> : (
        <table className="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{heading}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_calls")}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_errors")}</th>
              <th className="px-4 py-2">{t("mcp_tool_usage.col_error_rate")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {rows.map((row) => (
              <tr key={String(row[labelKey] ?? "unknown")}>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{row[labelKey] || t("mcp_tool_usage.unknown")}</td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{row.calls}</td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{row.errors}</td>
                <td className="px-4 py-2 align-top text-gray-700 dark:text-gray-200">{Math.round(row.error_rate * 1000) / 10}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
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
      render: (row) => formatEventDate(row.occurred_at)
    },
    {
      className: "px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200",
      headerClassName: "px-4 py-2",
      header: t("mcp_tool_usage.col_call"),
      key: "call",
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
          {row.job_path ? <Link className="text-blue-600 underline hover:no-underline dark:text-blue-300" to={row.job_path}>{t("mcp_tool_usage.link_job", { id: row.job_id })}</Link> : null}
          {row.workflow_path ? <Link className="text-blue-600 underline hover:no-underline dark:text-blue-300" to={row.workflow_path}>{t("mcp_tool_usage.link_workflow", { id: row.workflow_id })}</Link> : null}
          {row.run_path ? <Link className="text-blue-600 underline hover:no-underline dark:text-blue-300" to={row.run_path}>{t("mcp_tool_usage.link_run", { id: row.run_id })}</Link> : null}
          {row.chat_path ? <Link className="text-blue-600 underline hover:no-underline dark:text-blue-300" to={row.chat_path}>{t("mcp_tool_usage.link_chat")}</Link> : null}
        </div>
      )
    }
  ]

  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <h2 className="border-b border-gray-200 px-4 py-3 text-sm font-semibold text-gray-900 dark:border-gray-700 dark:text-gray-100">{t("mcp_tool_usage.recent_calls_heading")}</h2>
      {calls.length === 0 ? <AdminEventPanelMessage>{t("mcp_tool_usage.recent_calls_empty")}</AdminEventPanelMessage> : (
        <AdminEventLogTable columns={columns} getRowKey={(row) => row.id} rows={calls} />
      )}
    </section>
  )
}

export default AdminMcpToolUsage

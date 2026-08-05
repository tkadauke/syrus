import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { type FormEvent, type ReactNode, useMemo } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchAdminOperationalLogs, type OperationalLogRow, type OperationalLogsPayload } from "../api/adminOperationalLogs"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const levels = ["", "debug", "info", "warn", "error", "fatal", "unknown"] as const
const roles = ["", "web", "worker"] as const
const revisionScopes = ["current", "all"] as const

export function AdminOperationalLogs() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_operational_logs"))
  const search = normalizedSearch(location.search)
  const logs = useQuery({
    queryKey: ["admin", "operational_logs", search],
    queryFn: () => fetchAdminOperationalLogs(search),
    placeholderData: keepPreviousData
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <main aria-label={t("operational_logs.aria")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex flex-col gap-4 border-b border-gray-200 pb-4 dark:border-gray-700 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("operational_logs.heading")}</h1>
        </div>
        <button
          className="inline-flex w-fit items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
          disabled={logs.isFetching}
          onClick={() => void logs.refetch()}
          type="button"
        >
          {logs.isFetching ? t("operational_logs.refreshing") : t("operational_logs.refresh")}
        </button>
      </header>

      <OperationalLogFilters search={search} onNavigate={navigateSearch} />

      {logs.isPending ? <PanelMessage>{t("operational_logs.loading")}</PanelMessage> : null}
      {logs.isError ? <PanelMessage tone="error">{errorMessage(logs.error, t("operational_logs.error_load"))}</PanelMessage> : null}
      {logs.isSuccess ? <OperationalLogsView payload={logs.data} search={search} onNavigate={navigateSearch} /> : null}
    </main>
  )
}

function OperationalLogFilters({ onNavigate, search }: { onNavigate: (params: URLSearchParams) => void; search: string }) {
  const { t } = useT("admin")
  const params = useMemo(() => new URLSearchParams(search), [search])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const next = new URLSearchParams()
    setParam(next, "query", form.get("query"))
    setParam(next, "since", form.get("since"))
    setParam(next, "until", form.get("until"))
    setParam(next, "level", form.get("level"))
    setParam(next, "role", form.get("role"))
    setParam(next, "hostname", form.get("hostname"))
    setParam(next, "revision_scope", form.get("revision_scope"))
    setParam(next, "per_page", form.get("per_page") || params.get("per_page") || "50")
    onNavigate(next)
  }

  function clear() {
    onNavigate(new URLSearchParams())
  }

  return (
    <form className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900" onSubmit={submit}>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-6">
        <label className="space-y-1 md:col-span-2">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.query")}</span>
          <input className={inputClass()} defaultValue={params.get("query") || ""} name="query" placeholder={t("operational_logs.query_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.since")}</span>
          <input className={inputClass()} defaultValue={params.get("since") || "1h"} name="since" placeholder="1h" />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.until")}</span>
          <input className={inputClass()} defaultValue={params.get("until") || ""} name="until" placeholder={t("operational_logs.until_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.level")}</span>
          <select className={inputClass()} defaultValue={params.get("level") || ""} name="level">
            {levels.map((level) => <option key={level || "all"} value={level}>{level ? level.toUpperCase() : t("operational_logs.all_levels")}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.role")}</span>
          <select className={inputClass()} defaultValue={params.get("role") || ""} name="role">
            {roles.map((role) => <option key={role || "all"} value={role}>{role || t("operational_logs.all_roles")}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.hostname")}</span>
          <input className={inputClass()} defaultValue={params.get("hostname") || ""} name="hostname" placeholder="worker-0" />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.revision_scope")}</span>
          <select className={inputClass()} defaultValue={params.get("revision_scope") || "current"} name="revision_scope">
            {revisionScopes.map((scope) => <option key={scope} value={scope}>{t(`operational_logs.revision_${scope}`)}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("operational_logs.per_page")}</span>
          <select className={inputClass()} defaultValue={params.get("per_page") || "50"} name="per_page">
            {[25, 50, 100].map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
        </label>
        <div className="flex items-end gap-2">
          <button className="inline-flex items-center justify-center rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-gray-200" type="submit">
            {t("operational_logs.search")}
          </button>
          <button className="inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={clear} type="button">
            {t("operational_logs.clear")}
          </button>
        </div>
      </div>
    </form>
  )
}

function OperationalLogsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: OperationalLogsPayload; search: string }) {
  const { t } = useT("admin")
  if (!payload.enabled) {
    return <PanelMessage tone="warn">{payload.error?.message || t("operational_logs.disabled")}</PanelMessage>
  }

  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("operational_logs.showing", { count: payload.logs.length, page: payload.pagination.page })}</span>
        <span>{t("operational_logs.retention", { hours: Math.round(payload.retention_seconds / 3600), revision: payload.revision_scope === "all" ? t("operational_logs.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      {payload.logs.length > 0 ? <OperationalLogsTable rows={payload.logs} /> : <PanelMessage>{t("operational_logs.empty")}</PanelMessage>}
      <Pagination pagination={payload.pagination} search={search} onNavigate={onNavigate} />
    </section>
  )
}

function OperationalLogsTable({ rows }: { rows: OperationalLogRow[] }) {
  const { t } = useT("admin")
  return (
    <div className="overflow-x-auto">
      <table className="min-w-full table-fixed divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="w-44 px-4 py-2">{t("operational_logs.col_time")}</th>
            <th className="w-28 px-4 py-2">{t("operational_logs.col_level")}</th>
            <th className="w-56 px-4 py-2">{t("operational_logs.col_process")}</th>
            <th className="w-56 px-4 py-2">{t("operational_logs.col_refs")}</th>
            <th className="px-4 py-2">{t("operational_logs.col_message")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300">{formatDate(row.occurred_at)}</td>
              <td className="px-4 py-3 align-top"><LevelBadge level={row.level} /></td>
              <td className="px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200">
                <div className="font-medium">{row.role} · {row.hostname}</div>
                <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">{row.source}{row.pid ? ` · pid ${row.pid}` : ""}</div>
                <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">{shortRevision(row.app_revision)}</div>
              </td>
              <td className="px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300">{refsText(row)}</td>
              <td className="px-4 py-3 align-top">
                <div className="max-w-[56rem] overflow-hidden break-words font-mono text-xs leading-5 text-gray-900 dark:text-gray-100">{row.message}</div>
                {row.context && Object.keys(row.context).length > 0 ? <div className="mt-2 max-w-[56rem] overflow-hidden break-words font-mono text-xs leading-5 text-gray-500 dark:text-gray-400">{compactContext(row.context)}</div> : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Pagination({ onNavigate, pagination, search }: { onNavigate: (params: URLSearchParams) => void; pagination: OperationalLogsPayload["pagination"]; search: string }) {
  const { t } = useT("admin")
  function go(page: number | null | undefined) {
    if (!page) return
    const params = new URLSearchParams(search)
    params.set("page", String(page))
    onNavigate(params)
  }

  return (
    <div className="flex items-center justify-between border-t border-gray-200 px-4 py-3 text-sm dark:border-gray-700">
      <button className={pageButtonClass()} disabled={!pagination.has_previous_page} onClick={() => go(pagination.previous_page)} type="button">{t("operational_logs.previous")}</button>
      <span className="text-gray-600 dark:text-gray-300">{t("operational_logs.page", { page: pagination.page })}</span>
      <button className={pageButtonClass()} disabled={!pagination.has_next_page} onClick={() => go(pagination.next_page)} type="button">{t("operational_logs.next")}</button>
    </div>
  )
}

function LevelBadge({ level }: { level: string }) {
  const tone = level === "error" || level === "fatal"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
    : level === "warn"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-gray-50 text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200"
  return <span className={`inline-flex rounded border px-2 py-0.5 font-mono text-xs font-medium uppercase ${tone}`}>{level}</span>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "warn" }) {
  const toneClass = tone === "error"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
    : tone === "warn"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  return <div className={`rounded border p-4 text-sm ${toneClass}`}>{children}</div>
}

function setParam(params: URLSearchParams, key: string, value: FormDataEntryValue | null) {
  const text = String(value || "").trim()
  if (text) params.set(key, text)
}

function normalizedSearch(search: string) {
  if (search) return search
  return "?since=1h&revision_scope=current&per_page=50"
}

function inputClass() {
  return "w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-gray-500 focus:outline-none focus:ring-1 focus:ring-gray-500 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
}

function pageButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

function formatDate(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

function refsText(row: OperationalLogRow) {
  const refs = [
    row.job_id ? `JOB-${row.job_id}` : null,
    row.workflow_id ? `WF-${row.workflow_id}` : null,
    row.run_id ? `RUN-${row.run_id}` : null,
    row.request_id ? `REQ ${row.request_id}` : null
  ].filter(Boolean)
  return refs.length > 0 ? refs.join(" · ") : "-"
}

function compactContext(context: Record<string, string>) {
  return Object.entries(context).map(([key, value]) => `${key}=${value}`).join(" ")
}

function shortRevision(value: string | null | undefined) {
  if (!value) return "-"
  return value.length > 12 ? value.slice(0, 12) : value
}

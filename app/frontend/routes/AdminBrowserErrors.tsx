import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { type FormEvent, type ReactNode, useMemo, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchAdminBrowserErrors, type BrowserErrorEventRow, type BrowserErrorEventsPayload } from "../api/adminBrowserErrors"
import { AdminEventPageShell, AdminEventPagination, AdminEventPanelMessage, DetailBlock, JsonBlock, formatEventDate, inputClass, shortRevision } from "../components/AdminEventLogPanel"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const revisionScopes = ["current", "all"] as const

export function AdminBrowserErrors() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_browser_errors"))
  const search = normalizedSearch(location.search)
  const errors = useQuery({
    queryKey: ["admin", "browser_errors", search],
    queryFn: () => fetchAdminBrowserErrors(search),
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
          disabled={errors.isFetching}
          onClick={() => void errors.refetch()}
          type="button"
        >
          {errors.isFetching ? t("browser_errors.refreshing") : t("browser_errors.refresh")}
        </button>
      }
      ariaLabel={t("browser_errors.aria")}
      eyebrow={t("section_label")}
      title={t("browser_errors.heading")}
    >
      <BrowserErrorFilters search={search} onNavigate={navigateSearch} />
      {errors.isPending ? <AdminEventPanelMessage>{t("browser_errors.loading")}</AdminEventPanelMessage> : null}
      {errors.isError ? <AdminEventPanelMessage tone="error">{errorMessage(errors.error, t("browser_errors.error_load"))}</AdminEventPanelMessage> : null}
      {errors.isSuccess ? <BrowserErrorsView payload={errors.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function BrowserErrorFilters({ onNavigate, search }: { onNavigate: (params: URLSearchParams) => void; search: string }) {
  const { t } = useT("admin")
  const params = useMemo(() => new URLSearchParams(search), [search])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const next = new URLSearchParams()
    setParam(next, "query", form.get("query"))
    setParam(next, "since", form.get("since"))
    setParam(next, "until", form.get("until"))
    setParam(next, "fingerprint", form.get("fingerprint"))
    setParam(next, "path", form.get("path"))
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
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.query")}</span>
          <input className={inputClass()} defaultValue={params.get("query") || ""} name="query" placeholder={t("browser_errors.query_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.since")}</span>
          <input className={inputClass()} defaultValue={params.get("since") || "24h"} name="since" placeholder="24h" />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.until")}</span>
          <input className={inputClass()} defaultValue={params.get("until") || ""} name="until" placeholder={t("browser_errors.until_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.fingerprint")}</span>
          <input className={inputClass()} defaultValue={params.get("fingerprint") || ""} name="fingerprint" placeholder="sha..." />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.path")}</span>
          <input className={inputClass()} defaultValue={params.get("path") || ""} name="path" placeholder="/jobs/3188" />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.revision_scope")}</span>
          <select className={inputClass()} defaultValue={params.get("revision_scope") || "current"} name="revision_scope">
            {revisionScopes.map((scope) => <option key={scope} value={scope}>{t(`browser_errors.revision_${scope}`)}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("browser_errors.per_page")}</span>
          <select className={inputClass()} defaultValue={params.get("per_page") || "50"} name="per_page">
            {[25, 50, 100].map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
        </label>
        <div className="flex items-end gap-2">
          <button className="inline-flex items-center justify-center rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-gray-200" type="submit">
            {t("browser_errors.search")}
          </button>
          <button className="inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={clear} type="button">
            {t("browser_errors.clear")}
          </button>
        </div>
      </div>
    </form>
  )
}

function BrowserErrorsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: BrowserErrorEventsPayload; search: string }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("browser_errors.showing", { count: payload.events.length, page: payload.pagination.page })}</span>
        <span>{t("browser_errors.revision_hint", { revision: payload.revision_scope === "all" ? t("browser_errors.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      {payload.events.length > 0 ? <BrowserErrorsTable revisionScope={payload.revision_scope} rows={payload.events} /> : <AdminEventPanelMessage>{t("browser_errors.empty")}</AdminEventPanelMessage>}
      <AdminEventPagination
        label={t("browser_errors.page", { page: payload.pagination.page })}
        nextLabel={t("browser_errors.next")}
        previousLabel={t("browser_errors.previous")}
        pagination={payload.pagination}
        search={search}
        onNavigate={onNavigate}
      />
    </section>
  )
}

function BrowserErrorsTable({ revisionScope, rows }: { revisionScope: string; rows: BrowserErrorEventRow[] }) {
  const { t } = useT("admin")
  const [expandedId, setExpandedId] = useState<number | null>(null)
  return (
    <div className="overflow-x-auto">
      <table className="min-w-full table-fixed divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="w-36 px-4 py-2">{t("browser_errors.col_time")}</th>
            <th className="w-64 px-4 py-2">{t("browser_errors.col_path")}</th>
            <th className="px-4 py-2">{t("browser_errors.col_error")}</th>
            <th className="w-56 px-4 py-2">{t("browser_errors.col_user")}</th>
            <th className="w-32 px-4 py-2">{t("browser_errors.col_actions")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((row) => (
            <Row
              expanded={expandedId === row.id}
              key={row.id}
              revisionScope={revisionScope}
              row={row}
              onToggle={() => setExpandedId((current) => current === row.id ? null : row.id)}
            />
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Row({ expanded, onToggle, revisionScope, row }: { expanded: boolean; onToggle: () => void; revisionScope: string; row: BrowserErrorEventRow }) {
  const { t } = useT("admin")
  return (
    <>
      <tr>
        <td className="whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300">
          {formatEventDate(row.occurred_at)}
          {revisionScope === "all" ? <div className="mt-1 text-gray-500 dark:text-gray-400">{shortRevision(row.app_revision)}</div> : null}
        </td>
        <td className="px-4 py-3 align-top font-mono text-xs text-gray-700 dark:text-gray-200">
          <div className="break-words">{row.path || "-"}</div>
          {row.trace_id ? <div className="mt-1 text-gray-500 dark:text-gray-400">trace {row.trace_id}</div> : null}
        </td>
        <td className="px-4 py-3 align-top">
          <div className="break-words font-medium text-gray-900 dark:text-gray-100">{row.message}</div>
          <div className="mt-1 break-all font-mono text-xs text-gray-500 dark:text-gray-400">{row.name || "Error"} · {row.fingerprint}</div>
        </td>
        <td className="px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200">
          <div className="font-medium">{row.user.display_name || row.user.email_address || `User ${row.user.id}`}</div>
          {row.user_agent ? <div className="mt-1 line-clamp-2 text-gray-500 dark:text-gray-400">{row.user_agent}</div> : null}
        </td>
        <td className="px-4 py-3 align-top">
          <button className="rounded border border-gray-300 px-2.5 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800" onClick={onToggle} type="button">
            {expanded ? t("browser_errors.hide_details") : t("browser_errors.show_details")}
          </button>
        </td>
      </tr>
      {expanded ? (
        <tr>
          <td className="bg-gray-50 px-4 py-4 dark:bg-gray-950/40" colSpan={5}>
            <div className="grid gap-4 lg:grid-cols-2">
              <DetailBlock title={t("browser_errors.stack")} value={row.stack} />
              <DetailBlock title={t("browser_errors.component_stack")} value={row.component_stack} />
              <JsonBlock title={t("browser_errors.recent_api_requests")} value={row.recent_api_requests || []} />
              <JsonBlock title={t("browser_errors.recent_errors")} value={row.recent_errors || []} />
              <JsonBlock title={t("browser_errors.environment")} value={{ viewport: row.viewport || {}, feature_flags: row.feature_flags || {}, metadata: row.metadata || {}, route_params: row.route_params || {}, url: row.url }} />
            </div>
          </td>
        </tr>
      ) : null}
    </>
  )
}

function setParam(params: URLSearchParams, key: string, value: FormDataEntryValue | null) {
  const text = String(value || "").trim()
  if (text) params.set(key, text)
}

function normalizedSearch(search: string) {
  if (search) return search
  return "?since=24h&revision_scope=current&per_page=50"
}

export default AdminBrowserErrors

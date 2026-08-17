import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { type FormEvent, useMemo, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { fetchAdminBackendExceptions, type BackendExceptionEventRow, type BackendExceptionEventsPayload } from "../api/adminBackendExceptions"
import { AdminEventActions } from "../components/AdminEventActions"
import { AdminEventPageShell, AdminEventPagination, AdminEventPanelMessage, AdminEventTimeline, DetailBlock, JsonBlock, formatEventDate, inputClass, shortRevision } from "../components/AdminEventLogPanel"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const revisionScopes = ["current", "all"] as const

export function AdminBackendExceptions() {
  const { t } = useT("admin")
  const location = useLocation()
  const navigate = useNavigate()
  usePageTitle(t("page_title_backend_exceptions"))
  const search = normalizedSearch(location.search)
  const exceptions = useQuery({
    queryKey: ["admin", "backend_exceptions", search],
    queryFn: () => fetchAdminBackendExceptions(search),
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
          disabled={exceptions.isFetching}
          onClick={() => void exceptions.refetch()}
          type="button"
        >
          {exceptions.isFetching ? t("backend_exceptions.refreshing") : t("backend_exceptions.refresh")}
        </button>
      }
      ariaLabel={t("backend_exceptions.aria")}
      eyebrow={t("section_label")}
      title={t("backend_exceptions.heading")}
    >
      <BackendExceptionFilters search={search} payload={exceptions.data} onNavigate={navigateSearch} />
      {exceptions.isPending ? <AdminEventPanelMessage>{t("backend_exceptions.loading")}</AdminEventPanelMessage> : null}
      {exceptions.isError ? <AdminEventPanelMessage tone="error">{errorMessage(exceptions.error, t("backend_exceptions.error_load"))}</AdminEventPanelMessage> : null}
      {exceptions.isSuccess ? <BackendExceptionsView payload={exceptions.data} search={search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function BackendExceptionFilters({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload?: BackendExceptionEventsPayload; search: string }) {
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
    setParam(next, "source", form.get("source"))
    setParam(next, "exception_class", form.get("exception_class"))
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
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-7">
        <label className="space-y-1 md:col-span-2">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.query")}</span>
          <input className={inputClass()} defaultValue={params.get("query") || ""} name="query" placeholder={t("backend_exceptions.query_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.since")}</span>
          <input className={inputClass()} defaultValue={params.get("since") || "24h"} name="since" placeholder="24h" />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.until")}</span>
          <input className={inputClass()} defaultValue={params.get("until") || ""} name="until" placeholder={t("backend_exceptions.until_placeholder")} />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.source")}</span>
          <select className={inputClass()} defaultValue={params.get("source") || ""} name="source">
            <option value="">{t("backend_exceptions.all_sources")}</option>
            {(payload?.sources || []).map((source) => <option key={source} value={source}>{source}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.exception_class")}</span>
          <input className={inputClass()} defaultValue={params.get("exception_class") || ""} name="exception_class" placeholder="ActiveRecord::..." />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.path")}</span>
          <input className={inputClass()} defaultValue={params.get("path") || ""} name="path" placeholder="/api/..." />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.fingerprint")}</span>
          <input className={inputClass()} defaultValue={params.get("fingerprint") || ""} name="fingerprint" placeholder="sha..." />
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.revision_scope")}</span>
          <select className={inputClass()} defaultValue={params.get("revision_scope") || "current"} name="revision_scope">
            {revisionScopes.map((scope) => <option key={scope} value={scope}>{t(`backend_exceptions.revision_${scope}`)}</option>)}
          </select>
        </label>
        <label className="space-y-1">
          <span className="text-xs font-medium text-gray-600 dark:text-gray-300">{t("backend_exceptions.per_page")}</span>
          <select className={inputClass()} defaultValue={params.get("per_page") || "50"} name="per_page">
            {[25, 50, 100].map((value) => <option key={value} value={value}>{value}</option>)}
          </select>
        </label>
        <div className="flex items-end gap-2">
          <button className="inline-flex items-center justify-center rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-gray-200" type="submit">{t("backend_exceptions.search")}</button>
          <button className="inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={clear} type="button">{t("backend_exceptions.clear")}</button>
        </div>
      </div>
    </form>
  )
}

function BackendExceptionsView({ onNavigate, payload, search }: { onNavigate: (params: URLSearchParams) => void; payload: BackendExceptionEventsPayload; search: string }) {
  const { t } = useT("admin")
  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-2 border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300 sm:flex-row sm:items-center sm:justify-between">
        <span>{t("backend_exceptions.showing", { count: payload.events.length, page: payload.pagination.page })}</span>
        <span>{t("backend_exceptions.revision_hint", { revision: payload.revision_scope === "all" ? t("backend_exceptions.all_revisions") : shortRevision(payload.current_revision) })}</span>
      </div>
      <div className="border-b border-gray-200 p-4 dark:border-gray-700">
        <AdminEventTimeline buckets={payload.timeline || []} emptyLabel={t("backend_exceptions.timeline_empty")} title={t("backend_exceptions.timeline")} />
      </div>
      {payload.events.length > 0 ? <BackendExceptionsTable revisionScope={payload.revision_scope} rows={payload.events} /> : <AdminEventPanelMessage>{t("backend_exceptions.empty")}</AdminEventPanelMessage>}
      <AdminEventPagination
        label={t("backend_exceptions.page", { page: payload.pagination.page })}
        nextLabel={t("backend_exceptions.next")}
        previousLabel={t("backend_exceptions.previous")}
        pagination={payload.pagination}
        search={search}
        onNavigate={onNavigate}
      />
    </section>
  )
}

function BackendExceptionsTable({ revisionScope, rows }: { revisionScope: string; rows: BackendExceptionEventRow[] }) {
  const { t } = useT("admin")
  const [expandedId, setExpandedId] = useState<number | null>(null)
  return (
    <div className="overflow-x-auto">
      <table className="min-w-full table-fixed divide-y divide-gray-200 text-sm dark:divide-gray-700">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500 dark:bg-gray-800 dark:text-gray-400">
          <tr>
            <th className="w-36 px-4 py-2">{t("backend_exceptions.col_time")}</th>
            <th className="w-64 px-4 py-2">{t("backend_exceptions.col_context")}</th>
            <th className="px-4 py-2">{t("backend_exceptions.col_error")}</th>
            <th className="w-48 px-4 py-2">{t("backend_exceptions.col_runtime")}</th>
            <th className="w-32 px-4 py-2">{t("backend_exceptions.col_actions")}</th>
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

function Row({ expanded, onToggle, revisionScope, row }: { expanded: boolean; onToggle: () => void; revisionScope: string; row: BackendExceptionEventRow }) {
  const { t } = useT("admin")
  const context = row.source === "active_job"
    ? [row.job_class, row.queue_name ? `queue ${row.queue_name}` : null].filter(Boolean).join(" · ")
    : [row.method, row.path, row.status].filter(Boolean).join(" ")
  return (
    <>
      <tr>
        <td className="whitespace-nowrap px-4 py-3 align-top font-mono text-xs text-gray-600 dark:text-gray-300">
          {formatEventDate(row.occurred_at)}
          {revisionScope === "all" ? <div className="mt-1 text-gray-500 dark:text-gray-400">{shortRevision(row.app_revision)}</div> : null}
        </td>
        <td className="px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200">
          <div className="font-mono">{row.source}</div>
          <div className="mt-1 break-words">{context || "-"}</div>
          {row.job_id ? <Link className="mt-1 inline-block underline" to={`/jobs/${row.job_id}`}>JOB-{row.job_id}</Link> : null}
        </td>
        <td className="px-4 py-3 align-top">
          <div className="break-words font-medium text-gray-900 dark:text-gray-100">{row.message}</div>
          <div className="mt-1 break-all font-mono text-xs text-gray-500 dark:text-gray-400">{row.exception_class} · {row.fingerprint}</div>
        </td>
        <td className="px-4 py-3 align-top text-xs text-gray-700 dark:text-gray-200">
          <div>{row.role || "-"} {row.hostname ? `@ ${row.hostname}` : ""}</div>
          {row.request_id ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">request {row.request_id}</div> : null}
          {row.active_job_id ? <div className="mt-1 font-mono text-gray-500 dark:text-gray-400">active job {row.active_job_id}</div> : null}
        </td>
        <td className="px-4 py-3 align-top">
          <AdminEventActions actions={row.actions} eventId={row.id} eventType="backend_exception" showDetailsLabel={expanded ? t("backend_exceptions.hide_details") : t("backend_exceptions.show_details")} onToggleDetails={onToggle} />
        </td>
      </tr>
      {expanded ? (
        <tr>
          <td className="bg-gray-50 px-4 py-4 dark:bg-gray-950/40" colSpan={5}>
            <div className="grid gap-4 lg:grid-cols-2">
              <DetailBlock title={t("backend_exceptions.backtrace")} value={row.backtrace} />
              <JsonBlock title={t("backend_exceptions.request_context")} value={{ controller: row.controller, action: row.action, method: row.method, path: row.path, status: row.status, request_id: row.request_id }} />
              <JsonBlock title={t("backend_exceptions.job_context")} value={{ job_class: row.job_class, active_job_id: row.active_job_id, queue_name: row.queue_name, executions: row.executions, job_id: row.job_id, workflow_id: row.workflow_id, run_id: row.run_id }} />
              <JsonBlock title={t("backend_exceptions.environment")} value={{ role: row.role, hostname: row.hostname, pid: row.pid, metadata: row.metadata || {} }} />
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

export default AdminBackendExceptions

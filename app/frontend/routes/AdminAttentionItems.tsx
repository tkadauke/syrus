import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import {
  AdminEventFilterBar,
  AdminEventLogTable,
  type AdminEventLogTableColumn,
  AdminEventPageShell,
  AdminEventPanelMessage,
  JsonBlock,
  adminEventLinkClass,
  disabledPaginationClass,
  paginationLinkClass,
  severityPillClass
} from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { Input } from "../components/Input"
import { Select } from "../components/Select"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import {
  actOnAdminAttentionItem,
  decideAdminAttentionItem,
  fetchAdminAttentionItems,
  type AdminAttentionItemsPayload,
  type AttentionItemSummary
} from "../api/adminAttentionItems"
import { ApiError } from "../api/client"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { withRoutePrefix, routePrefix } from "../lib/routing"

const POLL_INTERVAL_MS = 30_000
const RESOLUTIONS = [ "upheld", "dismissed", "deferred" ]

export function AdminAttentionItems() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_attention_items"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const items = useQuery({
    queryKey: [ "admin", "attention_items", location.search ],
    queryFn: ({ signal }) => fetchAdminAttentionItems(location.search, signal),
    refetchInterval: POLL_INTERVAL_MS
  })

  function navigateSearch(params: URLSearchParams) {
    const next = params.toString()
    navigate({ pathname: location.pathname, search: next ? `?${next}` : "" })
  }

  return (
    <AdminEventPageShell
      actions={
        <Button className="shrink-0 disabled:text-gray-400 dark:disabled:text-gray-500" disabled={items.isFetching} onClick={() => void items.refetch()} variant="secondary">
          {items.isFetching ? t("attention_items.refreshing") : t("attention_items.refresh")}
        </Button>
      }
      ariaLabel={t("attention_items.aria")}
      eyebrow={t("section_label")}
      title={t("attention_items.heading")}
    >
      <p className="max-w-3xl text-sm text-gray-600 dark:text-gray-300">{t("attention_items.description")}</p>

      <AdminEventFilterBar clearLabel={t("attention_items.clear_filters")} filter={items.data?.filter} filterSchema={items.data?.filter_schema} fields={[
        { name: "state", label: t("attention_items.filter_state") },
        { name: "queue", label: t("attention_items.filter_queue") },
        { name: "urgency", label: t("attention_items.filter_urgency") },
        { name: "repository_id", label: t("attention_items.filter_repository"), inputMode: "numeric" }
      ]} search={location.search} searchLabel={t("attention_items.apply_filters")} />

      <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
        {items.isPending ? <AdminEventPanelMessage>{t("attention_items.loading")}</AdminEventPanelMessage> : null}
        {items.isError ? <AdminEventPanelMessage tone="error">{t("attention_items.error_load")}</AdminEventPanelMessage> : null}
        {items.isSuccess ? <ItemsTable payload={items.data} prefix={prefix} search={location.search} onNavigate={navigateSearch} /> : null}
      </section>
    </AdminEventPageShell>
  )
}

function ItemsTable({ onNavigate, payload, prefix, search }: { onNavigate: (params: URLSearchParams) => void; payload: AdminAttentionItemsPayload; prefix: string; search: string }) {
  const { t } = useT("admin")
  if (payload.items.length === 0) return <AdminEventPanelMessage>{t("attention_items.empty")}</AdminEventPanelMessage>

  const columns: Array<AdminEventLogTableColumn<AttentionItemSummary>> = [
    {
      className: "whitespace-nowrap px-4 py-3 text-xs text-gray-500 dark:text-gray-400",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_created"),
      key: "created",
      render: (item) => <RelativeTimestamp value={item.created_at} />
    },
    {
      className: "px-4 py-3",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_item"),
      key: "item",
      render: (item, { expanded, toggleExpanded }) => <ItemSummary item={item} onToggle={toggleExpanded} expanded={expanded} />
    },
    {
      className: "px-4 py-3 text-xs text-gray-600 dark:text-gray-300",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_scope"),
      key: "scope",
      render: (item) => <ScopeSummary item={item} prefix={prefix} />
    },
    {
      className: "px-4 py-3 text-xs",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_state"),
      key: "state",
      render: (item) => <StatePill item={item} />
    }
  ]

  return (
    <div>
      <div className="border-b border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
        {t("attention_items.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total })}
      </div>
      <AdminEventLogTable
        columns={columns}
        getRowKey={(item) => item.id}
        renderExpanded={(item) => <ItemDetail item={item} prefix={prefix} />}
        rows={payload.items}
        search={search}
        tableClassName="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700"
        onNavigate={onNavigate}
      />
      <Pagination pagination={payload.pagination} prefix={prefix} />
    </div>
  )
}

function ItemSummary({ item, expanded, onToggle }: { item: AttentionItemSummary; expanded: boolean; onToggle: () => void }) {
  const { t } = useT("admin")
  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2">
        <button className="font-semibold text-gray-900 hover:underline dark:text-gray-100" onClick={onToggle} type="button">
          {item.title}
        </button>
        <UrgencyPill urgency={item.urgency} />
        <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{item.queue}</span>
      </div>
      <div className="font-mono text-xs text-gray-500 dark:text-gray-400">{item.problem_label} ({item.problem_code})</div>
      {item.summary ? <div className="text-xs text-gray-600 dark:text-gray-300">{item.summary}</div> : null}
      <button className="text-xs text-brand underline hover:no-underline" onClick={onToggle} type="button">
        {expanded ? t("attention_items.hide_detail") : t("attention_items.show_detail")}
      </button>
    </div>
  )
}

function ScopeSummary({ item, prefix }: { item: AttentionItemSummary; prefix: string }) {
  return (
    <div className="space-y-1">
      {item.repository ? <Link className={adminEventLinkClass()} to={withRoutePrefix(item.repository.path, prefix)}>{item.repository.slug}</Link> : null}
      {item.job ? <div><Link className={adminEventLinkClass()} to={withRoutePrefix(item.job.path, prefix)}>{item.job.slug}</Link></div> : null}
      {item.workflow ? <div><Link className={adminEventLinkClass()} to={withRoutePrefix(item.workflow.path, prefix)}>{item.workflow.trigger_kind}</Link></div> : null}
    </div>
  )
}

function StatePill({ item }: { item: AttentionItemSummary }) {
  const label = item.state === "decided" && item.resolution ? `${item.state}: ${item.resolution}` : item.state
  const severity = item.state === "open" ? "warn" : item.state === "decided" && item.resolution === "upheld" ? "info" : "info"
  return <span className={`rounded px-1.5 py-0.5 font-mono text-xs ${severityPillClass(severity)}`}>{label}</span>
}

function UrgencyPill({ urgency }: { urgency: string }) {
  const severity = urgency === "urgent" ? "error" : urgency === "normal" ? "warn" : "info"
  return <span className={`rounded px-1.5 py-0.5 font-mono text-xs ${severityPillClass(severity)}`}>{urgency}</span>
}

function ItemDetail({ item, prefix }: { item: AttentionItemSummary; prefix: string }) {
  const { t } = useT("admin")
  return (
    <div className="space-y-4">
      <JsonBlock title={t("attention_items.evidence")} value={item.evidence} />
      {item.adjudication ? <AdjudicationBlock adjudication={item.adjudication} /> : null}
      {item.actions.length > 0 ? <ActionsBlock item={item} /> : null}
      {item.state === "open" ? <DecideForm item={item} /> : <DecidedSummary item={item} prefix={prefix} />}
    </div>
  )
}

function AdjudicationBlock({ adjudication }: { adjudication: NonNullable<AttentionItemSummary["adjudication"]> }) {
  const { t } = useT("admin")
  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.adjudication")}</h3>
      <div className="mt-2 rounded border border-gray-200 bg-white p-3 text-xs dark:border-gray-700 dark:bg-gray-900">
        <div><span className="font-medium">{t("attention_items.verdict")}:</span> {adjudication.verdict}</div>
        {adjudication.reason ? <div><span className="font-medium">{t("attention_items.reason")}:</span> {adjudication.reason}</div> : null}
        {adjudication.adjudicator ? <div><span className="font-medium">{t("attention_items.adjudicator")}:</span> {adjudication.adjudicator}</div> : null}
        {adjudication.confidence != null ? <div><span className="font-medium">{t("attention_items.confidence")}:</span> {adjudication.confidence}</div> : null}
      </div>
    </section>
  )
}

function ActionsBlock({ item }: { item: AttentionItemSummary }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [ reason, setReason ] = useState("")
  const act = useMutation({
    mutationFn: (actionKey: string) => actOnAdminAttentionItem(item.id, actionKey, reason.trim() || undefined),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: [ "admin", "attention_items" ] })
  })

  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.actions")}</h3>
      <div className="mt-2 space-y-2">
        {item.actions.map((action) => (
          <div className="flex flex-wrap items-center justify-between gap-2 rounded border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-900" key={action.action_key}>
            <div>
              <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{action.label || action.action_key}</div>
              {action.detail ? <div className="font-mono text-xs text-gray-500 dark:text-gray-400">{action.detail}</div> : null}
            </div>
            <Button disabled={act.isPending} onClick={() => act.mutate(action.action_key)} size="sm" variant="secondary">
              {act.isPending && act.variables === action.action_key ? t("attention_items.running") : t("attention_items.run_action")}
            </Button>
          </div>
        ))}
      </div>
      <label className="mt-2 block text-xs text-gray-500 dark:text-gray-400">
        {t("attention_items.action_reason_label")}
        <Input className="mt-1" onChange={(e) => setReason(e.target.value)} type="text" value={reason} />
      </label>
      {act.isError ? <AdminEventPanelMessage tone="error">{act.error instanceof ApiError ? act.error.message : t("attention_items.action_failed")}</AdminEventPanelMessage> : null}
    </section>
  )
}

function DecideForm({ item }: { item: AttentionItemSummary }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [ resolution, setResolution ] = useState(RESOLUTIONS[0])
  const [ reason, setReason ] = useState("")
  const decide = useMutation({
    mutationFn: () => decideAdminAttentionItem(item.id, resolution, reason.trim() || undefined),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: [ "admin", "attention_items" ] })
  })

  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.decide")}</h3>
      <div className="mt-2 flex flex-wrap items-end gap-2">
        <label className="text-xs text-gray-500 dark:text-gray-400">
          {t("attention_items.resolution_label")}
          <Select className="mt-1" fullWidth={false} onChange={(e) => setResolution(e.target.value)} value={resolution}>
            {RESOLUTIONS.map((value) => <option key={value} value={value}>{t(`attention_items.resolution_${value}`)}</option>)}
          </Select>
        </label>
        <label className="flex-1 text-xs text-gray-500 dark:text-gray-400">
          {t("attention_items.reason_label")}
          <Input className="mt-1" onChange={(e) => setReason(e.target.value)} type="text" value={reason} />
        </label>
        <Button disabled={decide.isPending} onClick={() => decide.mutate()} size="sm" variant="primary">
          {decide.isPending ? t("attention_items.deciding") : t("attention_items.decide")}
        </Button>
      </div>
      {decide.isError ? <AdminEventPanelMessage tone="error">{decide.error instanceof ApiError ? decide.error.message : t("attention_items.decide_failed")}</AdminEventPanelMessage> : null}
    </section>
  )
}

function DecidedSummary({ item, prefix }: { item: AttentionItemSummary; prefix: string }) {
  const { t } = useT("admin")
  return (
    <section className="text-xs text-gray-600 dark:text-gray-300">
      <span className="font-medium">{t(`attention_items.resolution_${item.resolution}`, { defaultValue: item.resolution || item.state })}</span>
      {item.decided_by ? <span> · {item.decided_by.display_name}</span> : null}
      {item.decided_at ? <span> · <RelativeTimestamp value={item.decided_at} /></span> : null}
      {item.reason ? <div className="mt-1">{item.reason}</div> : null}
      {item.job ? <div className="mt-1"><Link className={adminEventLinkClass()} to={withRoutePrefix(item.job.path, prefix)}>{item.job.slug}</Link></div> : null}
    </section>
  )
}

function Pagination({ pagination, prefix }: { pagination: AdminAttentionItemsPayload["pagination"]; prefix: string }) {
  const { t } = useT("admin")
  if (pagination.total_pages <= 1) return null
  return (
    <nav aria-label={t("attention_items.aria_pagination")} className="flex items-center justify-between border-t border-gray-200 px-4 py-3 text-sm text-gray-600 dark:border-gray-700 dark:text-gray-300">
      <span>{t("attention_items.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
      <div className="flex items-center gap-2">
        {pagination.previous_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.previous_path, prefix)}>{t("attention_items.previous")}</Link> : <span className={disabledPaginationClass()}>{t("attention_items.previous")}</span>}
        {pagination.next_path ? <Link className={paginationLinkClass()} to={withRoutePrefix(pagination.next_path, prefix)}>{t("attention_items.next")}</Link> : <span className={disabledPaginationClass()}>{t("attention_items.next")}</span>}
      </div>
    </nav>
  )
}

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
  severityPillClass
} from "../components/AdminEventLogPanel"
import { Button } from "../components/Button"
import { Input } from "../components/Input"
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
const RESOLUTIONS = ["upheld", "dismissed", "deferred"]
const EVIDENCE_LABELS: Record<string, string> = {
  app_revision: "App revision",
  classifier_attempts: "Classifier attempts",
  error_class: "Error class",
  error_message: "Error message",
  fingerprint: "Fingerprint",
  repository: "Repository",
  source_ref: "Source",
  step_kind: "Step",
  streak_count: "Failure streak",
  threshold: "Threshold",
  triaging_reason: "Triage reason",
  trigger_kind: "Workflow trigger",
  uncertainty_reason: "Detail"
}
const EVIDENCE_KEY_ORDER = [
  "repository",
  "source_ref",
  "triaging_reason",
  "uncertainty_reason",
  "classifier_attempts",
  "error_class",
  "error_message",
  "step_kind",
  "trigger_kind",
  "streak_count",
  "threshold",
  "app_revision",
  "fingerprint"
]

export function AdminAttentionItems() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_attention_items"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)
  const items = useQuery({
    queryKey: ["admin", "attention_items", location.search],
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
        <Button
          className="shrink-0 disabled:text-gray-400 dark:disabled:text-gray-500"
          disabled={items.isFetching}
          onClick={() => void items.refetch()}
          variant="secondary"
        >
          {items.isFetching ? t("attention_items.refreshing") : t("attention_items.refresh")}
        </Button>
      }
      ariaLabel={t("attention_items.aria")}
      description={t("attention_items.description")}
      eyebrow={t("section_label")}
      title={t("attention_items.heading")}
    >
      <AdminEventFilterBar
        clearLabel={t("attention_items.clear_filters")}
        filter={items.data?.filter}
        filterSchema={items.data?.filter_schema}
        fields={[
          { name: "state", label: t("attention_items.filter_state") },
          { name: "queue", label: t("attention_items.filter_queue") },
          { name: "urgency", label: t("attention_items.filter_urgency") },
          { name: "repository_id", label: t("attention_items.filter_repository"), inputMode: "numeric" }
        ]}
        search={location.search}
        searchLabel={t("attention_items.apply_filters")}
      />

      {items.isPending ? <AdminEventPanelMessage>{t("attention_items.loading")}</AdminEventPanelMessage> : null}
      {items.isError ? <AdminEventPanelMessage tone="error">{t("attention_items.error_load")}</AdminEventPanelMessage> : null}
      {items.isSuccess ? <ItemsTable payload={items.data} prefix={prefix} search={location.search} onNavigate={navigateSearch} /> : null}
    </AdminEventPageShell>
  )
}

function ItemsTable({
  onNavigate,
  payload,
  prefix,
  search
}: {
  onNavigate: (params: URLSearchParams) => void
  payload: AdminAttentionItemsPayload
  prefix: string
  search: string
}) {
  const { t } = useT("admin")
  if (payload.items.length === 0) return <AdminEventPanelMessage>{t("attention_items.empty")}</AdminEventPanelMessage>

  const columns: Array<AdminEventLogTableColumn<AttentionItemSummary>> = [
    {
      // Required columns are pinned to the declared start of the row, so
      // "item" (the only way to expand a row's detail) is declared first --
      // matching where it actually renders, instead of leaving it defined
      // after "created" and relying on required-pinning to silently move it.
      className: "px-4 py-3",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_item"),
      key: "item",
      required: true,
      sort: "problem",
      render: (item, { expanded, toggleExpanded }) => <ItemSummary item={item} onToggle={toggleExpanded} expanded={expanded} />
    },
    {
      className: "whitespace-nowrap px-4 py-3 text-xs text-gray-500 dark:text-gray-400",
      headerClassName: "px-4 py-2",
      header: t("attention_items.col_created"),
      key: "created",
      sort: "created_at",
      render: (item) => <RelativeTimestamp value={item.created_at} />
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
      sort: "state",
      render: (item) => <StatePill item={item} />
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      defaultSort={{ column: "urgency", direction: "asc" }}
      getRowKey={(item) => item.id}
      renderExpanded={(item) => <ItemDetail item={item} prefix={prefix} />}
      rows={payload.items}
      search={search}
      storageKey="syrus.admin.attention_items.visible_columns"
      tableClassName="min-w-full divide-y divide-gray-200 text-sm dark:divide-gray-700"
      onNavigate={onNavigate}
      panel={{
        summary: t("attention_items.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total }),
        pagination: {
          ariaLabel: t("attention_items.aria_pagination"),
          label: t("attention_items.page_of", { page: payload.pagination.page, total: payload.pagination.total_pages }),
          nextLabel: t("attention_items.next"),
          onNavigate,
          pagination: {
            page: payload.pagination.page,
            has_next_page: Boolean(payload.pagination.next_path),
            has_previous_page: Boolean(payload.pagination.previous_path),
            next_page: payload.pagination.page + 1,
            previous_page: payload.pagination.page - 1,
            total_pages: payload.pagination.total_pages
          },
          previousLabel: t("attention_items.previous"),
          search
        }
      }}
    />
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
      <div className="font-mono text-xs text-gray-500 dark:text-gray-400">
        {item.problem_label} ({item.problem_code})
      </div>
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
      {item.repository ? (
        <Link className={adminEventLinkClass()} to={withRoutePrefix(item.repository.path, prefix)}>
          {item.repository.slug}
        </Link>
      ) : null}
      {item.job ? (
        <div>
          <Link className={adminEventLinkClass()} to={withRoutePrefix(item.job.path, prefix)}>
            {item.job.slug}
          </Link>
        </div>
      ) : null}
      {item.workflow ? (
        <div>
          <Link className={adminEventLinkClass()} to={withRoutePrefix(item.workflow.path, prefix)}>
            {item.workflow.trigger_kind}
          </Link>
        </div>
      ) : null}
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
  return (
    <div className="space-y-4">
      <EvidenceBlock evidence={item.evidence} />
      {item.adjudication ? <AdjudicationBlock adjudication={item.adjudication} /> : null}
      {item.state === "open" ? <DecideForm item={item} /> : <DecidedSummary item={item} prefix={prefix} />}
      {item.actions.length > 0 ? <ActionsBlock item={item} /> : null}
    </div>
  )
}

function EvidenceBlock({ evidence }: { evidence: AttentionItemSummary["evidence"] }) {
  const { t } = useT("admin")
  const entries = evidenceEntries(evidence)

  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.evidence")}</h3>
      {entries.length > 0 ? (
        <dl className="mt-2 grid gap-2 rounded border border-border bg-surface p-3 text-xs sm:grid-cols-[minmax(8rem,14rem)_minmax(0,1fr)]">
          {entries.map(([key, value]) => (
            <div className="contents" key={key}>
              <dt className="font-medium text-text-secondary">{evidenceLabel(key)}</dt>
              <dd className="min-w-0 break-words text-text-primary">{formatEvidenceValue(key, value)}</dd>
            </div>
          ))}
        </dl>
      ) : (
        <div className="mt-2 rounded border border-border bg-surface p-3 text-xs text-text-muted">-</div>
      )}
      <details className="mt-2 rounded border border-border bg-surface p-3 text-xs">
        <summary className="cursor-pointer font-medium text-text-secondary">{t("attention_items.show_raw_evidence")}</summary>
        <div className="mt-3">
          <JsonBlock title={t("attention_items.raw_evidence")} value={evidence} />
        </div>
      </details>
    </section>
  )
}

function evidenceEntries(evidence: AttentionItemSummary["evidence"]) {
  const keys = Object.keys(evidence)
  const ordered = [...EVIDENCE_KEY_ORDER.filter((key) => keys.includes(key)), ...keys.filter((key) => !EVIDENCE_KEY_ORDER.includes(key)).sort()]
  return ordered.map((key) => [key, evidence[key]] as const).filter(([, value]) => value !== null && value !== undefined && value !== "")
}

function evidenceLabel(key: string) {
  return EVIDENCE_LABELS[key] || humanize(key)
}

function formatEvidenceValue(key: string, value: unknown) {
  if (key === "source_ref" && typeof value === "string") return formatSourceRef(value)
  if (["triaging_reason", "step_kind", "trigger_kind"].includes(key) && typeof value === "string") return humanize(value)
  if (typeof value === "boolean") return value ? "Yes" : "No"
  if (typeof value === "number") return value.toLocaleString()
  if (typeof value === "string") return value
  if (Array.isArray(value)) return value.map((entry) => formatCompactValue(entry)).join(", ")
  return formatCompactValue(value)
}

function formatSourceRef(value: string) {
  const githubIssue = value.match(/^github:[^#]+#(\d+)$/)
  if (githubIssue) return `GitHub issue #${githubIssue[1]}`
  return value
}

function formatCompactValue(value: unknown) {
  if (value === null || value === undefined) return "-"
  if (typeof value === "string") return value
  if (typeof value === "number") return value.toLocaleString()
  if (typeof value === "boolean") return value ? "Yes" : "No"
  return JSON.stringify(value)
}

function humanize(value: string) {
  return value.replace(/[_-]+/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function AdjudicationBlock({ adjudication }: { adjudication: NonNullable<AttentionItemSummary["adjudication"]> }) {
  const { t } = useT("admin")
  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.adjudication")}</h3>
      <div className="mt-2 rounded border border-border bg-surface p-3 text-xs text-text-primary">
        <div>
          <span className="font-medium">{t("attention_items.verdict")}:</span> {adjudication.verdict}
        </div>
        {adjudication.reason ? (
          <div>
            <span className="font-medium">{t("attention_items.reason")}:</span> {adjudication.reason}
          </div>
        ) : null}
        {adjudication.adjudicator ? (
          <div>
            <span className="font-medium">{t("attention_items.adjudicator")}:</span> {adjudication.adjudicator}
          </div>
        ) : null}
        {adjudication.confidence != null ? (
          <div>
            <span className="font-medium">{t("attention_items.confidence")}:</span> {adjudication.confidence}
          </div>
        ) : null}
      </div>
    </section>
  )
}

function ActionsBlock({ item }: { item: AttentionItemSummary }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [reasons, setReasons] = useState<Record<string, string>>({})
  const actions = item.actions.filter((action) => actionAppliesToItem(action.action_key, item))
  const act = useMutation({
    mutationFn: (actionKey: string) => actOnAdminAttentionItem(item.id, actionKey, reasons[actionKey]?.trim() || undefined),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: ["admin", "attention_items"] })
  })

  if (actions.length === 0) return null

  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.actions")}</h3>
      <div className="mt-2 space-y-2">
        {actions.map((action) => (
          <div className="rounded border border-border bg-surface p-2" key={action.action_key}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="min-w-0">
                <div className="text-sm font-medium text-text-primary">{action.label || action.action_key}</div>
                {action.detail ? <div className="break-words font-mono text-xs text-text-muted">{action.detail}</div> : null}
              </div>
              <Button disabled={act.isPending} onClick={() => act.mutate(action.action_key)} size="sm" variant="secondary">
                {act.isPending && act.variables === action.action_key ? t("attention_items.running") : t("attention_items.run_action")}
              </Button>
            </div>
            <details className="mt-2 text-xs text-text-muted">
              <summary className="cursor-pointer font-medium">{t("attention_items.add_action_reason")}</summary>
              <label className="mt-2 block" htmlFor={`attention-action-reason-${item.id}-${action.action_key}`}>
                {t("attention_items.action_reason_label")}
              </label>
              <Input
                className="mt-1"
                id={`attention-action-reason-${item.id}-${action.action_key}`}
                onChange={(event) => setReasons((current) => ({ ...current, [action.action_key]: event.target.value }))}
                type="text"
                value={reasons[action.action_key] || ""}
              />
            </details>
          </div>
        ))}
      </div>
      {act.isError ? (
        <AdminEventPanelMessage tone="error">{act.error instanceof ApiError ? act.error.message : t("attention_items.action_failed")}</AdminEventPanelMessage>
      ) : null}
    </section>
  )
}

function actionAppliesToItem(actionKey: string, item: AttentionItemSummary) {
  if (!actionKey.includes("cancel")) return true
  return item.job?.state !== "closed"
}

function DecideForm({ item }: { item: AttentionItemSummary }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [reason, setReason] = useState("")
  const decide = useMutation({
    mutationFn: (resolution: string) => decideAdminAttentionItem(item.id, resolution, reason.trim() || undefined),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: ["admin", "attention_items"] })
  })

  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("attention_items.decide")}</h3>
      <div className="mt-2 rounded border border-border bg-surface p-3">
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
          {RESOLUTIONS.map((value) => (
            <Button
              disabled={decide.isPending}
              key={value}
              onClick={() => decide.mutate(value)}
              size="sm"
              variant={value === "upheld" ? "primary" : "secondary"}
            >
              {decide.isPending && decide.variables === value ? t("attention_items.deciding") : t(`attention_items.resolution_${value}`)}
            </Button>
          ))}
        </div>
        <details className="mt-3 text-xs text-text-muted">
          <summary className="cursor-pointer font-medium">{t("attention_items.add_note")}</summary>
          <label className="mt-2 block" htmlFor={`attention-decision-reason-${item.id}`}>
            {t("attention_items.note_label")}
          </label>
          <Input className="mt-1" id={`attention-decision-reason-${item.id}`} onChange={(e) => setReason(e.target.value)} type="text" value={reason} />
        </details>
      </div>
      {decide.isError ? (
        <AdminEventPanelMessage tone="error">
          {decide.error instanceof ApiError ? decide.error.message : t("attention_items.decide_failed")}
        </AdminEventPanelMessage>
      ) : null}
    </section>
  )
}

function DecidedSummary({ item, prefix }: { item: AttentionItemSummary; prefix: string }) {
  const { t } = useT("admin")
  return (
    <section className="text-xs text-text-secondary">
      <span className="font-medium">{t(`attention_items.resolution_${item.resolution}`, { defaultValue: item.resolution || item.state })}</span>
      {item.decided_by ? <span> · {item.decided_by.display_name}</span> : null}
      {item.decided_at ? (
        <span>
          {" "}
          · <RelativeTimestamp value={item.decided_at} />
        </span>
      ) : null}
      {item.reason ? <div className="mt-1">{item.reason}</div> : null}
      {item.job ? (
        <div className="mt-1">
          <Link className={adminEventLinkClass()} to={withRoutePrefix(item.job.path, prefix)}>
            {item.job.slug}
          </Link>
        </div>
      ) : null}
    </section>
  )
}

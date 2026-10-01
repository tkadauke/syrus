import i18n from "i18next"
import type { ReactNode } from "react"
import { DataTable, Notice } from "@app/components/ui"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, FilterableList, PreviewTextBlock, Row as DetailRow, StatePill, displayValue, numberValue } from "@app/routes/chat/toolCardUi"
import { formatBytes, formatAge, formatMillicores } from "./lib/k8sFormat"

type K8sToolName =
  | "k8s_cluster_overview"
  | "k8s_cluster_list_clusters"
  | "k8s_cluster_namespaces"
  | "k8s_cluster_nodes"
  | "k8s_cluster_pods"
  | "k8s_cluster_pvcs"
  | "k8s_cluster_events"
  | "k8s_cluster_deployments"
  | "k8s_cluster_statefulsets"
  | "k8s_cluster_daemonsets"
  | "k8s_cluster_jobs"
  | "k8s_cluster_cronjobs"
  | "k8s_cluster_services"
  | "k8s_cluster_ingresses"
  | "k8s_cluster_configmaps"
  | "k8s_cluster_pod_logs"
  | "k8s_cluster_secrets"

type K8sRow = Record<string, unknown>
type Column = { key: string; label: string; render?: (row: K8sRow) => string | ReactNode; tone?: (row: K8sRow) => "success" | "warning" | "failure" | "neutral" | "info" }
type CardKind = "clusters" | "overview" | "namespaces" | "nodes" | "pods" | "pvcs" | "events" | "deployments" | "statefulsets" | "daemonsets" | "jobs" | "cronjobs" | "services" | "ingresses" | "configmaps" | "pod_logs" | "secrets"
type ParsedCard = {
  kind: CardKind
  rows: K8sRow[]
  truncated: boolean
  scope: string
  countLabel: string
  warningCount: number
  errorMessage: string | null
  overview?: OverviewCard
}
type OverviewSection = { available: boolean; items: K8sRow[]; totalCpuMillicores: number; totalMemoryBytes: number; message: string | null; reason: string | null }
type OverviewCard = { nodes: OverviewSection; pods: OverviewSection }

const TOOL_KINDS: Record<K8sToolName, CardKind> = {
  k8s_cluster_overview: "overview",
  k8s_cluster_list_clusters: "clusters",
  k8s_cluster_namespaces: "namespaces",
  k8s_cluster_nodes: "nodes",
  k8s_cluster_pods: "pods",
  k8s_cluster_pvcs: "pvcs",
  k8s_cluster_events: "events",
  k8s_cluster_deployments: "deployments",
  k8s_cluster_statefulsets: "statefulsets",
  k8s_cluster_daemonsets: "daemonsets",
  k8s_cluster_jobs: "jobs",
  k8s_cluster_cronjobs: "cronjobs",
  k8s_cluster_services: "services",
  k8s_cluster_ingresses: "ingresses",
  k8s_cluster_configmaps: "configmaps",
  k8s_cluster_pod_logs: "pod_logs",
  k8s_cluster_secrets: "secrets"
}

const ROW_LIMIT = 100

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`k8s_cluster:${key}`, options)
}

export function kubernetesToolCard(toolName: K8sToolName): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary,
    renderExpanded
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null
  if (card.errorMessage) return t("tool_card_error_summary", { scope: card.scope })

  const parts = [card.scope, card.countLabel]
  if (card.warningCount > 0) parts.push(t("tool_card_warning_count", { count: card.warningCount }))
  if (card.truncated) parts.push(t("tool_card_truncated"))
  return parts.join(" · ")
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.errorMessage) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={t("tool_card_error")} tone="failure" />
          <span className="text-xs font-medium text-text-primary">{card.scope}</span>
        </div>
        <Notice tone="danger">{card.errorMessage}</Notice>
      </CardShell>
    )
  }

  if (card.kind === "overview" && card.overview) return <OverviewBody card={card} overview={card.overview} />
  if (card.kind === "pod_logs") return <PodLogsBody card={card} />
  if (card.rows.length === 0) return <EmptyState>{t("tool_card_empty", { resource: resourceLabel(card.kind) })}</EmptyState>

  const columns = columnsFor(card.kind)
  const rows = card.rows.slice(0, ROW_LIMIT)
  return (
    <div className="mt-1 space-y-2">
      <SummaryStrip card={card} />
      <FilterableList
        itemText={(row) => JSON.stringify(row)}
        items={rows}
        placeholder={t("tool_card_filter_placeholder")}
      >
        {(visibleRows) => <KubernetesTable columns={columns} rows={visibleRows} />}
      </FilterableList>
      {card.rows.length > ROW_LIMIT ? <InlineNotice>{t("tool_card_preview_limited", { shown: ROW_LIMIT, total: card.rows.length })}</InlineNotice> : null}
      {card.truncated ? <InlineNotice>{t("truncated_notice")}</InlineNotice> : null}
    </div>
  )
}

function parseCard(context: ToolCardContext): ParsedCard | null {
  const kind = TOOL_KINDS[context.toolName as K8sToolName]
  if (!kind) return null

  const errorMessage = parseErrorMessage(context)
  if (errorMessage) return { kind, rows: [], truncated: false, scope: scopeLabel(context), countLabel: t("tool_card_no_resources"), warningCount: 1, errorMessage }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  if (kind === "overview") {
    const overview = parseOverview(parsed)
    if (!overview) return null
    return {
      kind,
      rows: [...overview.nodes.items, ...overview.pods.items],
      truncated: false,
      scope: scopeLabel(context),
      countLabel: t("tool_card_overview_counts", { nodes: overview.nodes.items.length, pods: overview.pods.items.length }),
      warningCount: [overview.nodes, overview.pods].filter((section) => !section.available).length,
      errorMessage: null,
      overview
    }
  }

  const rows = rowsForKind(kind, parsed)
  if (!rows) return null
  return {
    kind,
    rows,
    truncated: parsed.truncated === true,
    scope: scopeLabel(context),
    countLabel: t("tool_card_resource_count", { count: resourceCount(kind, rows), resource: resourceLabel(kind) }),
    warningCount: warningCount(kind, rows),
    errorMessage: null
  }
}

function parseErrorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  const body = context.resultBody.trim()
  if (!body) return t("tool_card_unknown_error")
  return body.replace(/^Error:\s*/i, "")
}

function scopeLabel(context: ToolCardContext) {
  const input = context.input || {}
  const clusterId = displayValue(input.cluster_id)
  const namespace = displayValue(input.namespace)
  const name = displayValue(input.name)
  if (clusterId && namespace && name) return t("tool_card_scope_cluster_namespace_resource", { cluster: clusterId, namespace, name })
  if (clusterId && namespace) return t("tool_card_scope_cluster_namespace", { cluster: clusterId, namespace })
  if (clusterId && name) return t("tool_card_scope_cluster_resource", { cluster: clusterId, name })
  if (clusterId) return t("tool_card_scope_cluster", { cluster: clusterId })
  return t("tool_card_scope_all_clusters")
}

function rowsForKind(kind: CardKind, parsed: Record<string, unknown>) {
  if (kind === "pod_logs") return [parsed]

  const key = collectionKey(kind)
  const rows = parsed[key]
  if (!Array.isArray(rows)) {
    const single = singularKey(kind)
    const row = single ? parsed[single] : null
    if (isPlainObject(row)) return [summarizeRawResource(kind, row as K8sRow)]
    return null
  }
  return rows.filter(isPlainObject) as K8sRow[]
}

function collectionKey(kind: CardKind) {
  if (kind === "clusters") return "clusters"
  if (kind === "pvcs") return "persistent_volume_claims"
  if (kind === "statefulsets") return "stateful_sets"
  if (kind === "daemonsets") return "daemon_sets"
  if (kind === "cronjobs") return "cron_jobs"
  if (kind === "configmaps") return "config_maps"
  return kind
}

function singularKey(kind: CardKind) {
  if (kind === "deployments") return "deployment"
  if (kind === "statefulsets") return "stateful_set"
  if (kind === "daemonsets") return "daemon_set"
  if (kind === "jobs") return "job"
  if (kind === "cronjobs") return "cron_job"
  if (kind === "services") return "service"
  if (kind === "ingresses") return "ingress"
  if (kind === "configmaps") return "config_map"
  if (kind === "secrets") return "secret"
  return null
}

function parseOverview(parsed: Record<string, unknown>): OverviewCard | null {
  if (!isPlainObject(parsed.nodes) || !isPlainObject(parsed.pods)) return null
  return { nodes: parseOverviewSection(parsed.nodes), pods: parseOverviewSection(parsed.pods) }
}

function parseOverviewSection(section: Record<string, unknown>): OverviewSection {
  const items = Array.isArray(section.items) ? section.items.filter(isPlainObject) as K8sRow[] : []
  return {
    available: section.available === true,
    items,
    totalCpuMillicores: numberValue(section.total_cpu_millicores) ?? 0,
    totalMemoryBytes: numberValue(section.total_memory_bytes) ?? 0,
    message: displayValue(section.message),
    reason: displayValue(section.reason)
  }
}

function warningCount(kind: CardKind, rows: K8sRow[]) {
  if (kind === "clusters") return rows.filter((row) => row.agentic_access_enabled !== true).length
  if (kind === "namespaces") return rows.filter((row) => displayValue(row.status) !== "Active").length
  if (kind === "nodes") return rows.filter((row) => row.ready !== true).length
  if (kind === "pods") return rows.filter((row) => !["Running", "Succeeded"].includes(displayValue(row.status) || "") || (numberValue(row.restart_count) ?? 0) > 0).length
  if (kind === "pvcs") return rows.filter((row) => displayValue(row.status) !== "Bound").length
  if (kind === "events") return rows.filter((row) => ["Warning", "Error"].includes(displayValue(row.type) || "")).length
  if (["deployments", "statefulsets"].includes(kind)) return rows.filter((row) => (numberValue(row.ready_replicas) ?? 0) < desiredReplicas(row)).length
  if (kind === "daemonsets") return rows.filter((row) => (numberValue(row.number_ready) ?? 0) < (numberValue(row.desired_number_scheduled) ?? 0)).length
  if (kind === "jobs") return rows.filter((row) => (numberValue(row.failed) ?? 0) > 0 || ((numberValue(row.completions) ?? 0) > 0 && (numberValue(row.succeeded) ?? 0) < (numberValue(row.completions) ?? 0))).length
  if (kind === "cronjobs") return rows.filter((row) => row.suspended === true).length
  if (kind === "services") return rows.filter((row) => row.missing_target_warning === true || (numberValue(row.not_ready_addresses) ?? 0) > 0).length
  if (kind === "ingresses") return rows.filter((row) => ingressBackends(row).length === 0).length
  return 0
}

function resourceCount(kind: CardKind, rows: K8sRow[]) {
  if (kind === "pod_logs") return logLines(rows[0]?.log).length
  return rows.length
}

function columnsFor(kind: CardKind): Column[] {
  if (kind === "clusters") {
    return [
      { key: "label", label: t("col_label") },
      { key: "id", label: t("tool_card_cluster_id") },
      { key: "agentic_access_enabled", label: t("col_agentic_access"), render: (row) => row.agentic_access_enabled === true ? t("agentic_enabled") : t("agentic_disabled"), tone: (row) => row.agentic_access_enabled === true ? "success" : "warning" },
      { key: "allow_writes", label: t("col_allow_writes"), render: (row) => row.allow_writes === true ? t("allow_writes_enabled") : t("allow_writes_disabled") },
      { key: "updated_at", label: t("col_updated"), render: (row) => formatAge(displayValue(row.updated_at)) }
    ]
  }
  if (kind === "namespaces") {
    return [
      { key: "name", label: t("col_name") },
      { key: "status", label: t("col_status"), tone: (row) => displayValue(row.status) === "Active" ? "success" : "warning" },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "nodes") {
    return [
      { key: "name", label: t("col_name") },
      { key: "ready", label: t("col_ready"), render: (row) => row.ready === true ? t("node_ready") : t("node_not_ready"), tone: (row) => row.ready === true ? "success" : "failure" },
      { key: "roles", label: t("col_roles"), render: (row) => arrayText(row.roles) },
      { key: "capacity", label: t("col_capacity"), render: (row) => nodeCapacity(row) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "pods") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "status", label: t("col_status"), tone: podTone },
      { key: "ready", label: t("col_ready") },
      { key: "restart_count", label: t("col_restarts"), tone: (row) => (numberValue(row.restart_count) ?? 0) > 0 ? "warning" : "neutral" },
      { key: "node_name", label: t("tool_card_node") },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "deployments") return workloadReplicaColumns("available_replicas")
  if (kind === "statefulsets") return workloadReplicaColumns("current_replicas")
  if (kind === "daemonsets") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "number_ready", label: t("col_ready"), render: (row) => `${numberValue(row.number_ready) ?? 0}/${numberValue(row.desired_number_scheduled) ?? 0}`, tone: (row) => (numberValue(row.number_ready) ?? 0) >= (numberValue(row.desired_number_scheduled) ?? 0) ? "success" : "warning" },
      { key: "current_number_scheduled", label: t("col_current") },
      { key: "number_available", label: t("col_available") },
      { key: "selector", label: t("col_selector"), render: (row) => selectorText(row.selector) },
      { key: "conditions", label: t("col_conditions"), render: (row) => conditionsText(row.conditions) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "jobs") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "completions", label: t("col_completions"), render: (row) => `${numberValue(row.succeeded) ?? 0}/${numberValue(row.completions) ?? "-"}`, tone: (row) => (numberValue(row.failed) ?? 0) > 0 ? "failure" : (numberValue(row.completions) ?? 0) > 0 && (numberValue(row.succeeded) ?? 0) >= (numberValue(row.completions) ?? 0) ? "success" : "info" },
      { key: "parallelism", label: t("col_parallelism") },
      { key: "active_count", label: t("col_active") },
      { key: "failed", label: t("col_failed"), tone: (row) => (numberValue(row.failed) ?? 0) > 0 ? "failure" : "neutral" },
      { key: "selector", label: t("col_selector"), render: (row) => selectorText(row.selector) },
      { key: "conditions", label: t("col_conditions"), render: (row) => conditionsText(row.conditions) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "cronjobs") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "schedule", label: t("col_schedule") },
      { key: "suspended", label: t("col_suspended"), render: (row) => row.suspended === true ? t("yes") : t("no"), tone: (row) => row.suspended === true ? "warning" : "success" },
      { key: "active_count", label: t("col_active") },
      { key: "last_schedule_time", label: t("col_last_seen"), render: (row) => formatAge(displayValue(row.last_schedule_time)) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "services") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "type", label: t("col_type") },
      { key: "cluster_ip", label: t("col_cluster_ip") },
      { key: "ports", label: t("col_ports"), render: (row) => portsText(row.ports) },
      { key: "endpoints", label: t("col_endpoints"), render: endpointsText, tone: (row) => row.missing_target_warning === true || (numberValue(row.not_ready_addresses) ?? 0) > 0 ? "warning" : (numberValue(row.ready_addresses) ?? 0) > 0 ? "success" : "neutral" },
      { key: "selector", label: t("col_selector"), render: (row) => selectorText(row.selector) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "ingresses") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "hosts", label: t("col_hosts"), render: (row) => arrayText(row.hosts) },
      { key: "backend", label: t("col_backend"), render: (row) => ingressBackends(row).join(", ") || t("tool_card_missing_backend"), tone: (row) => ingressBackends(row).length === 0 ? "warning" : "neutral" },
      { key: "tls_hosts", label: t("col_tls"), render: (row) => arrayText(row.tls_hosts) },
      { key: "ingress_class", label: t("col_ingress_class") },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "configmaps" || kind === "secrets") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      ...(kind === "secrets" ? [{ key: "type", label: t("col_type") }] : []),
      { key: "key_count", label: t("col_keys") },
      { key: "key_names", label: t("col_key_names"), render: (row) => arrayText(row.key_names) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "pvcs") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "status", label: t("col_status"), tone: (row) => displayValue(row.status) === "Bound" ? "success" : "warning" },
      { key: "capacity", label: t("col_capacity") },
      { key: "storage_class", label: t("col_storage_class") },
      { key: "access_modes", label: t("tool_card_access_modes"), render: (row) => arrayText(row.access_modes) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  return [
    { key: "namespace", label: t("col_namespace") },
    { key: "type", label: t("col_type"), tone: (row) => ["Warning", "Error"].includes(displayValue(row.type) || "") ? "warning" : "success" },
    { key: "reason", label: t("col_reason") },
    { key: "involved_object", label: t("col_object"), render: (row) => involvedObject(row.involved_object) },
    { key: "message", label: t("col_message") },
    { key: "count", label: t("col_count") },
    { key: "last_timestamp", label: t("col_last_seen"), render: (row) => formatAge(displayValue(row.last_timestamp)) }
  ]
}

function workloadReplicaColumns(currentKey: "available_replicas" | "current_replicas"): Column[] {
  return [
    { key: "namespace", label: t("col_namespace") },
    { key: "name", label: t("col_name") },
    { key: "ready_replicas", label: t("col_ready"), render: (row) => `${numberValue(row.ready_replicas) ?? 0}/${desiredReplicas(row)}`, tone: (row) => (numberValue(row.ready_replicas) ?? 0) >= desiredReplicas(row) ? "success" : "warning" },
    { key: currentKey, label: currentKey === "available_replicas" ? t("col_available") : t("col_current") },
    { key: "updated_replicas", label: t("col_updated") },
    { key: "selector", label: t("col_selector"), render: (row) => selectorText(row.selector) },
    { key: "conditions", label: t("col_conditions"), render: (row) => conditionsText(row.conditions) },
    { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
  ]
}

function KubernetesTable({ columns, rows }: { columns: Column[]; rows: K8sRow[] }) {
  return (
    <DataTable.Root className="min-w-max text-left text-xs" density="compact">
      <DataTable.Header>
        <DataTable.Row>
          {columns.map((column) => <DataTable.HeadCell className="px-2 py-1 text-2xs" key={column.key}>{column.label}</DataTable.HeadCell>)}
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {rows.map((row, index) => (
          <DataTable.Row key={rowKey(row, index)}>
            {columns.map((column) => <DataTable.Cell className="max-w-80 px-2 py-1 text-text-secondary" key={column.key}>{cell(column, row)}</DataTable.Cell>)}
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function cell(column: Column, row: K8sRow) {
  const rendered = column.render ? column.render(row) : valueText(row[column.key])
  const text = typeof rendered === "string" ? rendered : null
  const tone = column.tone?.(row)
  if (tone && text) return <StatePill state={text} tone={tone} />
  if (text) return <span className="block truncate" title={text}>{text}</span>
  return rendered
}

function SummaryStrip({ card }: { card: ParsedCard }) {
  return (
    <div className="grid gap-2 sm:grid-cols-3">
      <DetailRow label={t("tool_card_scope")} value={card.scope} />
      <DetailRow label={t("tool_card_resources")} value={card.countLabel} />
      <DetailRow label={t("tool_card_health")} value={card.warningCount > 0 ? t("tool_card_warning_count", { count: card.warningCount }) : t("tool_card_no_warnings")} />
    </div>
  )
}

function PodLogsBody({ card }: { card: ParsedCard }) {
  const row = card.rows[0] || {}
  const lines = logLines(row.log)

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-3">
        <DetailRow label={t("logs_pod_label")} value={displayValue(row.pod) || "-"} />
        <DetailRow label={t("logs_container_label")} value={displayValue(row.container) || t("tool_card_default_container")} />
        <DetailRow label={t("logs_tail_lines_label")} value={String(lines.length)} />
      </div>
      <FilterableList emptyLabel={t("logs_search_no_matches")} itemText={(line) => line} items={lines} placeholder={t("logs_search_placeholder")}>
        {(visibleLines) => <PreviewTextBlock emptyLabel={t("logs_empty")} maxLines={80} text={visibleLines.join("\n")} />}
      </FilterableList>
    </CardShell>
  )
}

function OverviewBody({ card, overview }: { card: ParsedCard; overview: OverviewCard }) {
  return (
    <CardShell>
      <SummaryStrip card={card} />
      <OverviewSection title={t("overview_node_usage")} section={overview.nodes} />
      <OverviewSection title={t("overview_pod_usage")} section={overview.pods} />
    </CardShell>
  )
}

function OverviewSection({ section, title }: { section: OverviewSection; title: string }) {
  if (!section.available) {
    return <Notice title={title} tone="warning">{section.message || section.reason || t("overview_metrics_unavailable")}</Notice>
  }

  return (
    <div className="space-y-1">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <span className="font-semibold text-text-primary">{title}</span>
        <StatePill state={t("tool_card_resource_count", { count: section.items.length, resource: t("tool_card_items") })} tone="success" />
        <span className="text-text-muted">{formatMillicores(section.totalCpuMillicores)}</span>
        <span className="text-text-muted">{formatBytes(section.totalMemoryBytes)}</span>
      </div>
      {section.items.length > 0 ? (
        <KubernetesTable
          columns={[
            { key: "namespace", label: t("col_namespace") },
            { key: "name", label: t("col_name") },
            { key: "cpu_millicores", label: t("col_cpu"), render: (row) => formatMillicores(numberValue(row.cpu_millicores) ?? 0) },
            { key: "memory_bytes", label: t("col_memory"), render: (row) => formatBytes(numberValue(row.memory_bytes) ?? 0) }
          ]}
          rows={section.items.slice(0, ROW_LIMIT)}
        />
      ) : <EmptyState>{t("tool_card_empty", { resource: t("tool_card_items") })}</EmptyState>}
    </div>
  )
}

function InlineNotice({ children }: { children: string }) {
  return <div className="text-2xs text-text-muted">{children}</div>
}

function resourceLabel(kind: CardKind) {
  return t(`tool_card_resource_${kind}`)
}

function valueText(value: unknown): string {
  if (Array.isArray(value)) return arrayText(value)
  if (typeof value === "boolean") return value ? t("yes") : t("no")
  return displayValue(value) || "-"
}

function desiredReplicas(row: K8sRow) {
  return numberValue(row.replicas) ?? 0
}

function arrayText(value: unknown): string {
  return Array.isArray(value) ? value.map((entry) => String(entry)).join(", ") || "-" : valueText(value)
}

function nodeCapacity(row: K8sRow) {
  const cpu = displayValue(row.capacity_cpu)
  const memory = displayValue(row.capacity_memory)
  return [cpu, memory].filter(Boolean).join(" / ") || "-"
}

function selectorText(value: unknown) {
  if (isPlainObject(value)) {
    const parts = Object.entries(value).map(([key, entry]) => `${key}=${String(entry)}`)
    return parts.join(", ") || "-"
  }
  return displayValue(value) || "-"
}

function conditionsText(value: unknown) {
  if (!Array.isArray(value)) return "-"
  const parts = value.filter(isPlainObject).slice(0, 3).map((condition) => {
    const type = displayValue(condition.type)
    const status = displayValue(condition.status)
    const reason = displayValue(condition.reason)
    return [type, status, reason].filter(Boolean).join(":")
  })
  return parts.join(", ") || "-"
}

function portsText(value: unknown) {
  if (!Array.isArray(value)) return "-"
  return value.filter(isPlainObject).map((port) => {
    const portNumber = displayValue(port.port)
    const protocol = displayValue(port.protocol)
    const targetPort = displayValue(port.target_port)
    return `${portNumber || "?"}${protocol ? `/${protocol}` : ""}${targetPort ? ` -> ${targetPort}` : ""}`
  }).join(", ") || "-"
}

function endpointsText(row: K8sRow) {
  if (row.missing_target_warning === true) return t("tool_card_missing_targets")
  const ready = numberValue(row.ready_addresses)
  const notReady = numberValue(row.not_ready_addresses)
  if (ready == null && notReady == null) return "-"
  return t("services_endpoints_ready", { ready: ready ?? 0, total: (ready ?? 0) + (notReady ?? 0) })
}

function ingressBackends(row: K8sRow) {
  if (!Array.isArray(row.rules)) return []
  return row.rules.filter(isPlainObject).flatMap((rule) => {
    if (!Array.isArray(rule.paths)) return []
    return rule.paths.filter(isPlainObject).map((path) => {
      const service = isPlainObject(path.backend) && isPlainObject(path.backend.service) ? path.backend.service : null
      const servicePort = service && isPlainObject(service.port) ? service.port : null
      const serviceName = displayValue(path.service_name) || displayValue(service?.name)
      const port = displayValue(path.service_port) || displayValue(servicePort?.number) || displayValue(servicePort?.name)
      return [serviceName, port].filter(Boolean).join(":")
    }).filter(Boolean)
  })
}

function logLines(value: unknown) {
  const log = displayValue(value) ?? ""
  return log ? log.split("\n") : []
}

function ingressRuleSummaries(rules: unknown) {
  if (!Array.isArray(rules)) return []
  return rules.filter(isPlainObject).map((rule) => ({
    host: rule.host,
    paths: ingressPathSummaries(rule)
  }))
}

function ingressPathSummaries(rule: K8sRow) {
  const paths = isPlainObject(rule.http) && Array.isArray(rule.http.paths) ? rule.http.paths : Array.isArray(rule.paths) ? rule.paths : []
  return paths.filter(isPlainObject).map((path) => {
    const service = isPlainObject(path.backend) && isPlainObject(path.backend.service) ? path.backend.service : null
    const servicePort = service && isPlainObject(service.port) ? service.port : null
    return {
      path: path.path,
      path_type: path.pathType || path.path_type,
      service_name: service?.name || path.service_name,
      service_port: servicePort?.number || servicePort?.name || path.service_port
    }
  })
}

function ingressHosts(rules: unknown) {
  if (!Array.isArray(rules)) return []
  return rules.map((rule) => isPlainObject(rule) ? rule.host : null).filter(Boolean)
}

function tlsHosts(tls: unknown) {
  if (!Array.isArray(tls)) return []
  return tls.flatMap((entry) => isPlainObject(entry) && Array.isArray(entry.hosts) ? entry.hosts : [])
}

function involvedObject(value: unknown) {
  if (!isPlainObject(value)) return "-"
  return [displayValue(value.kind), displayValue(value.name)].filter(Boolean).join(" / ") || "-"
}

function podTone(row: K8sRow) {
  const status = displayValue(row.status)
  if (status === "Running" || status === "Succeeded") return "success"
  if (status === "Pending") return "warning"
  return "failure"
}

function rowKey(row: K8sRow, index: number) {
  return [row.namespace, row.name, row.id, row.reason, row.last_timestamp].map((part) => displayValue(part)).filter(Boolean).join(":") || String(index)
}

function summarizeRawResource(kind: CardKind, row: K8sRow): K8sRow {
  const metadata = isPlainObject(row.metadata) ? row.metadata : {}
  const spec = isPlainObject(row.spec) ? row.spec : {}
  const status = isPlainObject(row.status) ? row.status : {}
  const base = {
    name: metadata.name,
    namespace: metadata.namespace,
    created_at: metadata.creationTimestamp,
    selector: isPlainObject(spec.selector) ? spec.selector.matchLabels : spec.selector,
    conditions: Array.isArray(status.conditions) ? status.conditions : []
  }

  if (kind === "deployments") return { ...base, replicas: numberValue(spec.replicas), ready_replicas: numberValue(status.readyReplicas) ?? 0, available_replicas: numberValue(status.availableReplicas) ?? 0, updated_replicas: numberValue(status.updatedReplicas) ?? 0 }
  if (kind === "statefulsets") return { ...base, replicas: numberValue(spec.replicas), ready_replicas: numberValue(status.readyReplicas) ?? 0, current_replicas: numberValue(status.currentReplicas) ?? 0, updated_replicas: numberValue(status.updatedReplicas) ?? 0 }
  if (kind === "daemonsets") return { ...base, desired_number_scheduled: numberValue(status.desiredNumberScheduled) ?? 0, current_number_scheduled: numberValue(status.currentNumberScheduled) ?? 0, number_ready: numberValue(status.numberReady) ?? 0, number_available: numberValue(status.numberAvailable) ?? 0 }
  if (kind === "jobs") return { ...base, completions: numberValue(spec.completions), parallelism: numberValue(spec.parallelism), active_count: numberValue(status.active) ?? 0, succeeded: numberValue(status.succeeded) ?? 0, failed: numberValue(status.failed) ?? 0 }
  if (kind === "cronjobs") return { ...base, schedule: spec.schedule, suspended: spec.suspend === true, active_count: Array.isArray(status.active) ? status.active.length : 0, last_schedule_time: status.lastScheduleTime }
  if (kind === "services") return { ...base, type: spec.type, cluster_ip: spec.clusterIP, ports: Array.isArray(spec.ports) ? spec.ports : [], selector: spec.selector }
  if (kind === "ingresses") return { ...base, ingress_class: spec.ingressClassName, hosts: ingressHosts(spec.rules), rules: ingressRuleSummaries(spec.rules), tls_hosts: tlsHosts(spec.tls) }
  if (kind === "configmaps") return { ...base, key_count: Object.keys(isPlainObject(row.data) ? row.data : {}).length, key_names: Object.keys(isPlainObject(row.data) ? row.data : {}).sort() }
  if (kind === "secrets") return row
  return row
}

export function kubernetesToolCardExamples(toolName: K8sToolName): ToolCardExample[] {
  const kind = TOOL_KINDS[toolName]
  const input = kind === "clusters" ? {} : { cluster_id: 7, ...(["pods", "pvcs", "events", "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs", "services", "ingresses", "configmaps", "pod_logs", "secrets"].includes(kind) ? { namespace: "default" } : {}), ...(kind === "pod_logs" ? { name: "web-7d9b", tail_lines: 200 } : {}) }
  return [
    { id: "healthy", label: "Healthy result", input, parsedResult: examplePayload(kind, "healthy") },
    { id: "warning_heavy", label: "Warning-heavy result", input, parsedResult: examplePayload(kind, "warning") },
    { id: "empty", label: "Empty result", input, parsedResult: examplePayload(kind, "empty") },
    { id: "error", label: "Error result", input, resultBody: "Error: Kubernetes cluster not found", resultError: true }
  ]
}

function examplePayload(kind: CardKind, variant: "healthy" | "warning" | "empty") {
  if (kind === "overview") return overviewExample(variant)
  if (kind === "clusters") return { clusters: variant === "empty" ? [] : [{ id: 7, label: "Production", agentic_access_enabled: variant !== "warning", allow_writes: false, updated_at: "2026-09-30T12:00:00Z" }] }
  if (kind === "namespaces") return { available: true, truncated: false, namespaces: variant === "empty" ? [] : [{ name: "default", status: variant === "warning" ? "Terminating" : "Active", created_at: "2026-09-01T12:00:00Z" }] }
  if (kind === "nodes") return { available: true, truncated: false, nodes: variant === "empty" ? [] : [{ name: "node-1", ready: variant !== "warning", roles: ["control-plane"], capacity_cpu: "4", capacity_memory: "16Gi", created_at: "2026-09-01T12:00:00Z" }] }
  if (kind === "pods") return { available: true, truncated: variant === "warning", pods: variant === "empty" ? [] : [{ namespace: "default", name: "web-7d9b", status: variant === "warning" ? "CrashLoopBackOff" : "Running", ready: variant === "warning" ? "0/1" : "1/1", restart_count: variant === "warning" ? 14 : 0, node_name: "node-1", created_at: "2026-09-30T10:00:00Z" }] }
  if (kind === "pvcs") return { available: true, truncated: false, persistent_volume_claims: variant === "empty" ? [] : [{ namespace: "default", name: "data-postgres-0", status: variant === "warning" ? "Pending" : "Bound", capacity: "20Gi", storage_class: "fast", access_modes: ["ReadWriteOnce"], created_at: "2026-09-10T12:00:00Z" }] }
  if (kind === "deployments") return { available: true, truncated: variant === "warning", deployments: variant === "empty" ? [] : [{ namespace: "default", name: "web", replicas: 3, ready_replicas: variant === "warning" ? 1 : 3, available_replicas: variant === "warning" ? 1 : 3, updated_replicas: variant === "warning" ? 2 : 3, selector: { app: "web" }, conditions: [{ type: "Available", status: variant === "warning" ? "False" : "True", reason: variant === "warning" ? "MinimumReplicasUnavailable" : "MinimumReplicasAvailable" }], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "statefulsets") return { available: true, truncated: false, stateful_sets: variant === "empty" ? [] : [{ namespace: "default", name: "postgres", replicas: 3, ready_replicas: variant === "warning" ? 2 : 3, current_replicas: 3, updated_replicas: variant === "warning" ? 2 : 3, selector: { app: "postgres" }, conditions: [{ type: "Available", status: variant === "warning" ? "False" : "True" }], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "daemonsets") return { available: true, truncated: false, daemon_sets: variant === "empty" ? [] : [{ namespace: "kube-system", name: "node-agent", desired_number_scheduled: 4, current_number_scheduled: 4, number_ready: variant === "warning" ? 3 : 4, number_available: variant === "warning" ? 3 : 4, selector: { app: "node-agent" }, conditions: [{ type: "Available", status: variant === "warning" ? "False" : "True" }], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "jobs") return { available: true, truncated: false, jobs: variant === "empty" ? [] : [{ namespace: "default", name: "migrate", completions: 1, parallelism: 1, active_count: variant === "warning" ? 0 : 0, succeeded: variant === "warning" ? 0 : 1, failed: variant === "warning" ? 1 : 0, selector: { "job-name": "migrate" }, conditions: [{ type: variant === "warning" ? "Failed" : "Complete", status: "True" }], created_at: "2026-09-30T11:00:00Z" }] }
  if (kind === "cronjobs") return { available: true, truncated: false, cron_jobs: variant === "empty" ? [] : [{ namespace: "default", name: "nightly", schedule: "0 2 * * *", suspended: variant === "warning", active_count: 0, last_schedule_time: "2026-09-30T02:00:00Z", created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "services") return { available: true, truncated: false, services: variant === "empty" ? [] : [{ namespace: "default", name: "web", type: "ClusterIP", cluster_ip: "10.0.0.10", external_ips: [], ports: [{ name: "http", port: 80, target_port: 8080, protocol: "TCP" }], selector: { app: "web" }, ready_addresses: variant === "warning" ? 0 : 2, not_ready_addresses: variant === "warning" ? 1 : 0, missing_target_warning: variant === "warning", created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "ingresses") return { available: true, truncated: false, ingresses: variant === "empty" ? [] : [{ namespace: "default", name: "web", ingress_class: "nginx", hosts: ["app.example.test"], rules: variant === "warning" ? [] : [{ host: "app.example.test", paths: [{ path: "/", path_type: "Prefix", service_name: "web", service_port: 80 }] }], tls_hosts: variant === "warning" ? [] : ["app.example.test"], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "configmaps") return { available: true, truncated: false, config_maps: variant === "empty" ? [] : [{ namespace: "default", name: "web-config", key_count: 2, key_names: ["LOG_LEVEL", "PUBLIC_URL"], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "secrets") return { available: true, truncated: false, secrets: variant === "empty" ? [] : [{ namespace: "default", name: "web-secret", type: "Opaque", key_count: 2, key_names: ["API_TOKEN", "DATABASE_URL"], created_at: "2026-09-20T12:00:00Z" }] }
  if (kind === "pod_logs") return { available: true, generated_at: "2026-09-30T12:00:00Z", pod: "web-7d9b", namespace: "default", container: "web", log: variant === "empty" ? "" : [`2026-09-30T12:00:00Z boot complete`, variant === "warning" ? "2026-09-30T12:00:02Z ERROR database timeout" : "2026-09-30T12:00:02Z request complete"].join("\n") }
  return { available: true, truncated: variant === "warning", events: variant === "empty" ? [] : [{ namespace: "default", type: variant === "warning" ? "Warning" : "Normal", reason: variant === "warning" ? "FailedScheduling" : "Pulled", message: variant === "warning" ? "0/3 nodes are available" : "Container image pulled", involved_object: { kind: "Pod", name: "web-7d9b" }, count: variant === "warning" ? 8 : 1, last_timestamp: "2026-09-30T12:00:00Z" }] }
}

function overviewExample(variant: "healthy" | "warning" | "empty") {
  const empty = variant === "empty"
  return {
    generated_at: "2026-09-30T12:00:00Z",
    nodes: variant === "warning"
      ? { available: false, reason: "metrics_unavailable", message: "metrics.k8s.io is not available" }
      : { available: true, items: empty ? [] : [{ name: "node-1", cpu_millicores: 840, memory_bytes: 8_589_934_592 }], total_cpu_millicores: empty ? 0 : 840, total_memory_bytes: empty ? 0 : 8_589_934_592 },
    pods: { available: true, items: empty ? [] : [{ namespace: "default", name: "web-7d9b", cpu_millicores: 120, memory_bytes: 268_435_456 }], total_cpu_millicores: empty ? 0 : 120, total_memory_bytes: empty ? 0 : 268_435_456 }
  }
}

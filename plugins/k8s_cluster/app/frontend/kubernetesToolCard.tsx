import i18n from "i18next"
import { useState, type ReactNode } from "react"
import { Button } from "@app/components/Button"
import { CodeSurface, DataTable, Notice } from "@app/components/ui"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import {
  CardShell,
  Disclosure,
  EmptyState,
  EntityReference,
  FilterableList,
  Row as DetailRow,
  StatePill,
  displayValue,
  numberValue
} from "@app/routes/chat/toolCardUi"
import { MarkdownPreview, TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { redactToolCardText } from "@app/toolCardSecurity"
import { formatBytes, formatAge, formatKubernetesCpu, formatKubernetesMemory, formatMillicores } from "./lib/k8sFormat"

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
type K8sActionToolName = "k8s_cluster_restart_rollout" | "k8s_cluster_scale_deployment" | "k8s_cluster_delete_pod" | "k8s_cluster_set_node_cordon"
type K8sKubectlToolName = "k8s_cluster_kubectl"

type K8sRow = Record<string, unknown>
type Column = {
  key: string
  label: string
  render?: (row: K8sRow) => string | ReactNode
  tone?: (row: K8sRow) => "success" | "warning" | "failure" | "neutral" | "info"
}
type CardKind =
  | "clusters"
  | "overview"
  | "namespaces"
  | "nodes"
  | "pods"
  | "pvcs"
  | "events"
  | "deployments"
  | "statefulsets"
  | "daemonsets"
  | "jobs"
  | "cronjobs"
  | "services"
  | "ingresses"
  | "configmaps"
  | "pod_logs"
  | "secrets"
type ParsedCard = {
  kind: CardKind
  rows: K8sRow[]
  truncated: boolean
  scope: string
  countLabel: string
  warningCount: number
  errorMessage: string | null
  clusterId: string | null
  namespace: string | null
  name: string | null
  generatedAt: string | null
  overview?: OverviewCard
}
type OverviewSection = {
  available: boolean
  items: K8sRow[]
  totalCpuMillicores: number
  totalMemoryBytes: number
  message: string | null
  reason: string | null
}
type OverviewCard = { nodes: OverviewSection; pods: OverviewSection }
type ActionKind = "restart_rollout" | "scale_deployment" | "delete_pod" | "set_node_cordon"
type ActionErrorKind = "permission" | "missing_resource" | "validation" | "api"
type ParsedActionCard = {
  kind: ActionKind
  actionLabel: string
  target: string
  scope: string
  resultState: "succeeded" | "no_op" | "failed"
  requestedChange: string
  previousState: string | null
  currentState: string | null
  clusterId: string | null
  namespace: string | null
  resourceName: string | null
  generatedAt: string | null
  followUpChecks: string[]
  errorKind: ActionErrorKind | null
  errorMessage: string | null
  available: boolean | null
  before: Record<string, unknown>
}
type ParsedKubectlCard = {
  ok: boolean
  payload: boolean
  status: string
  command: string
  scope: string
  credentialId: string
  credentialName: string
  credentialType: string
  cluster: string
  context: string
  host: string
  allowSecretOutput: boolean
  allowRiskyCommand: boolean
  permissionDenied: boolean
  stdout: string
  stderr: string
  stdoutTruncation: TextBlockTruncation | null
  stderrTruncation: TextBlockTruncation | null
  errorMessage: string | null
}
type TextBlockTruncation = { bytes: number | null; omittedBytes: number | null }

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
const RESPONSIVE_TABLE_KINDS = new Set<CardKind>(["ingresses", "configmaps", "secrets"])
const CONFIG_MAP_VALUE_DISPLAY_LIMIT = 4_096
const CONFIG_MAP_VALUE_PREVIEW_LIMIT = 320
const RESPONSIVE_TABLE_BODY_CLASSES = [
  "block divide-y-0 space-y-2 bg-transparent",
  "[&>tr]:block [&>tr]:h-auto [&>tr]:rounded-[var(--radius-panel)] [&>tr]:border [&>tr]:border-border [&>tr]:bg-surface [&>tr]:py-1",
  "sm:table-row-group sm:divide-y sm:space-y-0 sm:bg-surface",
  "sm:[&>tr]:table-row sm:[&>tr]:h-[var(--data-table-row-min-height)] sm:[&>tr]:rounded-none sm:[&>tr]:border-0 sm:[&>tr]:py-0"
].join(" ")
const RESPONSIVE_TABLE_CELL_CLASSES = [
  "grid min-w-0 max-w-none grid-cols-[minmax(5rem,0.4fr)_minmax(0,1fr)]",
  "items-start gap-3 px-3 py-1 text-text-secondary",
  "sm:table-cell sm:max-w-80 sm:px-2"
].join(" ")

const ACTION_KINDS: Record<K8sActionToolName, ActionKind> = {
  k8s_cluster_restart_rollout: "restart_rollout",
  k8s_cluster_scale_deployment: "scale_deployment",
  k8s_cluster_delete_pod: "delete_pod",
  k8s_cluster_set_node_cordon: "set_node_cordon"
}

const ACTION_RESOURCE_LINKS: Record<ActionKind, { tab: string; key: string }> = {
  restart_rollout: { tab: "deployments", key: "deployment" },
  scale_deployment: { tab: "deployments", key: "deployment" },
  delete_pod: { tab: "pods", key: "pod" },
  set_node_cordon: { tab: "nodes", key: "node" }
}

const TOOL_ARGUMENT_SUMMARIES: Partial<Record<K8sToolName, () => string>> = {
  k8s_cluster_namespaces: () => ""
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`k8s_cluster:${key}`, options)
}

export function kubernetesToolCard(toolName: K8sToolName): ToolCardRenderer {
  return {
    toolName,
    argumentSummary: TOOL_ARGUMENT_SUMMARIES[toolName],
    collapsedSummary,
    renderExpanded
  }
}

export function kubernetesActionToolCard(toolName: K8sActionToolName): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary: collapsedActionSummary,
    renderExpanded: renderExpandedAction
  }
}

export function kubernetesKubectlToolCard(toolName: K8sKubectlToolName): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary: collapsedKubectlSummary,
    renderExpanded: renderExpandedKubectl
  }
}

function collapsedKubectlSummary(context: ToolCardContext) {
  const card = parseKubectlCard(context)
  if (!card) return null

  return t("kubectl_card_summary", {
    command: card.command,
    scope: card.scope,
    status: kubectlStateLabel(card)
  })
}

function renderExpandedKubectl(context: ToolCardContext) {
  const card = parseKubectlCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={kubectlStateLabel(card)} tone={kubectlStateTone(card)} />
        {card.allowSecretOutput ? <StatePill state={t("kubectl_card_secret_output_enabled")} tone="warning" /> : null}
        {card.allowRiskyCommand ? <StatePill state={t("kubectl_card_risky_command_enabled")} tone="warning" /> : null}
      </div>
      <CodeSurface code={card.command} copyLabel={t("kubectl_card_copy_command")} maxHeightClassName="max-h-24" />
      {card.errorMessage ? (
        <Notice tone="danger" title={kubectlErrorTitle(card)}>
          {card.errorMessage}
        </Notice>
      ) : null}
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <DetailRow label={t("action_card_scope")} value={card.scope} />
        <DetailRow label={t("kubectl_card_status")} value={card.status} />
        <DetailRow label={t("kubectl_card_cluster")} value={card.cluster} />
        <DetailRow label={t("kubectl_card_context")} value={card.context} />
        <DetailRow label={t("kubectl_card_host")} value={card.host} />
        <DetailRow label={t("kubectl_card_credential_name")} value={card.credentialName} />
        <DetailRow label={t("kubectl_card_credential_id")} value={card.credentialId} />
        <DetailRow label={t("kubectl_card_credential_type")} value={card.credentialType} />
      </div>
      {card.allowSecretOutput ? <Notice tone="warning">{t("kubectl_card_secret_output_suppressed")}</Notice> : null}
      {card.stdout || card.stdoutTruncation ? (
        <KubectlTextPreview failed={!card.ok} label={t("kubectl_card_stdout")} text={card.stdout} truncation={card.stdoutTruncation} />
      ) : null}
      {card.stderr || card.stderrTruncation ? (
        <KubectlTextPreview defaultOpen={!card.ok} failed={!card.ok} label={t("kubectl_card_stderr")} text={card.stderr} truncation={card.stderrTruncation} />
      ) : null}
    </CardShell>
  )
}

function collapsedActionSummary(context: ToolCardContext) {
  const card = parseActionCard(context)
  if (!card) return null

  return t("action_card_summary", {
    action: card.actionLabel,
    target: card.target,
    scope: card.scope,
    state: actionStateLabel(card.resultState, card.errorKind)
  })
}

function renderExpandedAction(context: ToolCardContext) {
  const card = parseActionCard(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={actionStateLabel(card.resultState, card.errorKind)} tone={actionStateTone(card)} />
        <span className="text-xs font-medium text-text-primary">{card.actionLabel}</span>
        <ActionTarget card={card} />
      </div>
      {card.errorMessage ? (
        <Notice tone="danger" title={actionErrorTitle(card.errorKind)}>
          {card.errorMessage}
        </Notice>
      ) : null}
      <div className="grid gap-2 sm:grid-cols-2">
        <ActionScope card={card} />
        <DetailRow label={t("action_card_requested_change")} value={card.requestedChange} />
        <DetailRow label={t("action_card_previous_state")} value={card.previousState || t("action_card_not_available")} />
        <DetailRow label={t("action_card_current_state")} value={card.currentState || t("action_card_not_available")} />
      </div>
      {card.kind === "delete_pod" && card.resultState === "succeeded" ? <DeletePodDetails card={card} /> : null}
      {card.generatedAt ? <div className="text-2xs text-text-muted">{t("action_card_generated_at", { timestamp: card.generatedAt })}</div> : null}
      <div className="space-y-1">
        <div className="text-2xs font-semibold uppercase text-text-muted">{t("action_card_follow_up_checks")}</div>
        <ul className="list-disc space-y-1 pl-4 text-xs text-text-secondary">
          {card.followUpChecks.map((check) => (
            <li key={check}>{check}</li>
          ))}
        </ul>
      </div>
    </CardShell>
  )
}

function DeletePodDetails({ card }: { card: ParsedActionCard }) {
  const ownerKind = displayValue(card.before.owner_kind)
  const ownerName = displayValue(card.before.owner_name)
  const owner = ownerKind && ownerName ? `${ownerKind}/${ownerName}` : t("delete_pod_bare_owner")
  const outcome = ownerKind && ownerName ? t("delete_pod_controller_outcome", { kind: ownerKind, name: ownerName }) : t("delete_pod_bare_outcome")

  return (
    <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
      <DetailRow label={t("delete_pod_available")} value={card.available === null ? t("action_card_not_available") : String(card.available)} />
      <DetailRow label={t("delete_pod_owner")} value={owner} />
      <DetailRow label={t("delete_pod_outcome")} value={outcome} />
      <DetailRow label={t("delete_pod_node")} value={displayValue(card.before.node_name) || t("action_card_not_available")} />
      <DetailRow label={t("delete_pod_phase")} value={displayValue(card.before.phase) || t("action_card_not_available")} />
      <DetailRow label={t("delete_pod_restarts")} value={displayValue(card.before.restart_count) || t("action_card_not_available")} />
    </div>
  )
}

function ActionScope({ card }: { card: ParsedActionCard }) {
  if (!card.clusterId) return <DetailRow label={t("action_card_scope")} value={card.scope} />

  return (
    <div className="min-w-0">
      <div className="text-2xs font-semibold uppercase text-text-muted">{t("action_card_scope")}</div>
      <div className="flex flex-wrap items-center gap-x-1 text-xs text-text-primary">
        <EntityReference kind="cluster" id={card.clusterId} label={t("tool_card_scope_cluster", { cluster: card.clusterId })} />
        {card.namespace ? (
          <>
            <span>/</span>
            <EntityReference
              href={clusterResourceHref({ cluster_id: card.clusterId, namespace: card.namespace }, "namespaces")}
              kind="namespace"
              label={card.namespace}
            />
          </>
        ) : null}
      </div>
    </div>
  )
}

function ActionTarget({ card }: { card: ParsedActionCard }) {
  const resource = ACTION_RESOURCE_LINKS[card.kind]
  const href = clusterResourceHref({ cluster_id: card.clusterId, namespace: card.namespace }, resource.tab, resource.key, card.resourceName)

  return <EntityReference href={href} kind="artifact" label={card.target} slug={card.target} wrap="break" />
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
        <ScopeDetail card={card} />
        <StatePill state={t("tool_card_error")} tone="failure" />
        <Notice tone="danger">{card.errorMessage}</Notice>
      </CardShell>
    )
  }

  if (card.kind === "overview" && card.overview) return <OverviewBody card={card} overview={card.overview} />
  if (card.kind === "pod_logs") return <PodLogsBody card={card} />
  if (card.rows.length === 0)
    return (
      <CardShell>
        <SummaryStrip card={card} />
        <EmptyState>{t("tool_card_empty", { resource: resourceLabel(card.kind) })}</EmptyState>
      </CardShell>
    )
  if (card.kind === "events") return <EventsBody card={card} />
  if (card.kind === "nodes" && card.name) return <NodeDescribeBody card={card} node={card.rows[0]} />
  if (card.kind === "pods" && card.name) return <PodDescribeBody card={card} pod={card.rows[0]} />
  if (card.kind === "pvcs" && card.name) return <PvcDescribeBody card={card} pvc={card.rows[0]} />
  if (card.kind === "configmaps" && card.name) return <ConfigMapDescribeBody card={card} configMap={card.rows[0]} />
  if (card.kind === "secrets" && card.name) return <SecretDescribeBody card={card} secret={card.rows[0]} />

  const columns = columnsFor(card.kind)
  return (
    <div className="mt-1 space-y-2">
      <SummaryStrip card={card} />
      <FilterableList itemText={(row) => JSON.stringify(row)} items={card.rows} placeholder={t("tool_card_filter_placeholder")}>
        {(visibleRows) => <KubernetesTable columns={columns} responsive={RESPONSIVE_TABLE_KINDS.has(card.kind)} rows={visibleRows.slice(0, ROW_LIMIT)} />}
      </FilterableList>
      {card.rows.length > ROW_LIMIT ? <InlineNotice>{t("tool_card_preview_limited", { shown: ROW_LIMIT, total: card.rows.length })}</InlineNotice> : null}
      {card.truncated ? <InlineNotice>{t("truncated_notice")}</InlineNotice> : null}
    </div>
  )
}

function parseKubectlCard(context: ToolCardContext): ParsedKubectlCard | null {
  const parsed = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const payload = "ok" in parsed && "status" in parsed
  const input = context.input || {}
  const allowSecretOutput = input.allow_secret_output === true
  const safeStdout = redactToolCardText(textBlockValue(parsed.stdout))
  const safeStderr = redactToolCardText(textBlockValue(parsed.stderr))
  const parsedError = payload && parsed.ok !== true ? kubectlFailureMessage(safeStderr, parsed.status) : parseErrorMessage(context)
  const permissionDenied = kubectlPermissionDeniedText(parsedError || safeStderr)
  const errorMessage = allowSecretOutput && parsedError ? kubectlFailureMessage("", parsed.status) : parsedError
  const command = kubectlCommand(parsed, context.input || {})
  const statusValue = displayValue(parsed.status)
  const credential = isPlainObject(parsed.credential) ? parsed.credential : {}
  const metadata = isPlainObject(parsed.safe_metadata) ? parsed.safe_metadata : {}
  const target = isPlainObject(parsed.target) ? parsed.target : {}
  const unknown = t("action_card_unknown")

  return {
    ok: parsed.ok === true,
    payload,
    status: statusValue ? t("kubectl_card_status_value", { status: statusValue }) : errorMessage ? t("tool_card_error") : t("action_card_unknown"),
    command,
    scope: kubectlScope(parsed, input),
    credentialId: displayValue(credential.credential_id) || displayValue(parsed.credential_id) || unknown,
    credentialName: displayValue(credential.credential_name) || displayValue(parsed.credential_name) || displayValue(input.credential) || unknown,
    credentialType: displayValue(credential.credential_type) || displayValue(parsed.credential_type) || unknown,
    cluster: displayValue(metadata.cluster) || displayValue(input.cluster) || displayValue(input.cluster_id) || unknown,
    context:
      displayValue(metadata.context) || displayValue(metadata.kube_context) || displayValue(target.kube_context) || displayValue(input.kube_context) || unknown,
    host: displayValue(metadata.host) || unknown,
    allowSecretOutput,
    allowRiskyCommand: input.allow_risky_command === true,
    permissionDenied,
    stdout: allowSecretOutput ? "" : safeStdout,
    stderr: allowSecretOutput ? "" : safeStderr,
    stdoutTruncation: allowSecretOutput ? null : textBlockTruncation(parsed.stdout),
    stderrTruncation: allowSecretOutput ? null : textBlockTruncation(parsed.stderr),
    errorMessage
  }
}

function kubectlStateLabel(card: ParsedKubectlCard) {
  if (card.ok) return t("action_state_succeeded")
  if (kubectlPermissionDenied(card)) return t("action_failure_permission")
  return card.payload ? t("action_failure_api") : t("action_failure_validation")
}

function kubectlStateTone(card: ParsedKubectlCard) {
  if (card.ok) return "success"
  return card.payload ? "failure" : "warning"
}

function kubectlPermissionDenied(card: ParsedKubectlCard) {
  return card.permissionDenied
}

function kubectlPermissionDeniedText(text: string) {
  return /(?:permission|policy|forbidden|not allowed|access (?:is )?disabled|could expose secret)/i.test(text)
}

function kubectlErrorTitle(card: ParsedKubectlCard) {
  if (kubectlPermissionDenied(card)) return t("action_error_permission_title")
  return card.payload ? t("action_error_api_title") : t("action_error_validation_title")
}

function kubectlFailureMessage(stderr: string, status: unknown) {
  const lines = stderr
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
  if (lines.length > 0) return lines.slice(0, 3).join("\n")
  return t("kubectl_card_exited", { status: displayValue(status) || t("action_card_unknown") })
}

function KubectlTextPreview({
  defaultOpen = false,
  failed,
  label,
  text,
  truncation
}: {
  defaultOpen?: boolean
  failed: boolean
  label: string
  text: string
  truncation: TextBlockTruncation | null
}) {
  return (
    <div className="space-y-1">
      {truncation ? <StatePill state={truncationLabel(truncation)} tone="warning" /> : null}
      <Disclosure defaultOpen={defaultOpen} label={label}>
        <TextPreview modalLabel={label} text={text} truncate={failed ? "tail" : "head"} />
      </Disclosure>
    </div>
  )
}

function truncationLabel(truncation: TextBlockTruncation) {
  if (truncation.bytes !== null && truncation.omittedBytes !== null)
    return t("kubectl_card_truncated_bytes_omitted", { bytes: formatBytes(truncation.bytes), omittedBytes: formatBytes(truncation.omittedBytes) })
  if (truncation.omittedBytes !== null) return t("kubectl_card_truncated_omitted", { bytes: formatBytes(truncation.omittedBytes) })
  if (truncation.bytes !== null) return t("kubectl_card_truncated_bytes", { bytes: formatBytes(truncation.bytes) })
  return t("tool_card_truncated")
}

function kubectlCommand(parsed: Record<string, unknown>, input: Record<string, unknown>) {
  const parsedCommand =
    isPlainObject(parsed.command) && Array.isArray(parsed.command.args) ? parsed.command.args.map(displayValue).filter(Boolean).join(" ") : null
  const inputCommand = Array.isArray(input.args) ? input.args.map(displayValue).filter(Boolean).join(" ") : null
  return `kubectl ${parsedCommand || inputCommand || ""}`.trim()
}

function kubectlScope(parsed: Record<string, unknown>, input: Record<string, unknown>) {
  const target = isPlainObject(parsed.target) ? parsed.target : {}
  const kubeContext = displayValue(target.kube_context) || displayValue(input.kube_context)
  const namespace = displayValue(target.kube_namespace) || displayValue(target.namespace) || displayValue(input.namespace)
  if (kubeContext && namespace) return t("kubectl_card_scope_context_namespace", { context: kubeContext, namespace })
  if (kubeContext) return t("kubectl_card_scope_context", { context: kubeContext })
  if (namespace) return t("kubectl_card_scope_namespace", { namespace })
  return t("tool_card_scope_all_clusters")
}

function textBlockValue(value: unknown) {
  if (isPlainObject(value)) return displayValue(value.text) || ""
  return displayValue(value) || ""
}

function textBlockTruncation(value: unknown): TextBlockTruncation | null {
  if (!isPlainObject(value) || value.truncated !== true) return null
  return { bytes: numberValue(value.bytes), omittedBytes: numberValue(value.omitted_bytes) }
}

function parseCard(context: ToolCardContext): ParsedCard | null {
  const kind = TOOL_KINDS[context.toolName as K8sToolName]
  if (!kind) return null

  const errorMessage = parseErrorMessage(context)
  if (errorMessage)
    return {
      kind,
      rows: [],
      truncated: false,
      scope: scopeLabel(context),
      countLabel: t("tool_card_no_resources"),
      warningCount: 1,
      errorMessage,
      ...scopeDetails(context),
      generatedAt: null
    }

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
      ...scopeDetails(context),
      generatedAt: displayValue(parsed.generated_at),
      overview
    }
  }

  const parsedRows = rowsForKind(kind, parsed)
  if (!parsedRows) return null
  const clusterId = displayValue((context.input || {}).cluster_id)
  const rows =
    kind === "pod_logs"
      ? parsedRows.map((row) => ({
          ...row,
          container: row.container ?? context.input?.container,
          previous: context.input?.previous === true,
          requested_tail_lines: context.input?.tail_lines,
          timestamps: context.input?.timestamps === true
        }))
      : ["pods", "events", "services"].includes(kind)
        ? parsedRows.map((row) => ({ ...row, cluster_id: clusterId }))
        : parsedRows
  return {
    kind,
    rows,
    truncated: parsed.truncated === true,
    scope: scopeLabel(context),
    countLabel: t("tool_card_resource_count", { count: resourceCount(kind, rows), resource: resourceLabel(kind) }),
    warningCount: warningCount(kind, rows),
    errorMessage: null,
    ...scopeDetails(context),
    generatedAt: displayValue(parsed.generated_at)
  }
}

function scopeDetails(context: ToolCardContext) {
  const input = context.input || {}
  return {
    clusterId: displayValue(input.cluster_id),
    namespace: displayValue(input.namespace),
    name: displayValue(input.name)
  }
}

function parseActionCard(context: ToolCardContext): ParsedActionCard | null {
  const kind = ACTION_KINDS[context.toolName as K8sActionToolName]
  if (!kind) return null

  const parsed = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const errorMessage = parseErrorMessage(context)
  const before = isPlainObject(parsed.before) ? parsed.before : {}
  const after = isPlainObject(parsed.after) ? parsed.after : {}
  const input = context.input || {}
  const clusterId = displayValue(input.cluster_id)
  const namespace = displayValue(parsed.namespace) || displayValue(input.namespace)
  const resourceName = displayValue(parsed.deployment) || displayValue(parsed.pod) || displayValue(parsed.node) || displayValue(input.name)
  const target = actionTarget(kind, parsed, input)
  const errorKind = errorMessage ? classifyActionError(errorMessage) : null
  const resultState = errorMessage ? "failed" : actionNoOp(kind, before, after) ? "no_op" : "succeeded"

  return {
    kind,
    actionLabel: actionLabel(kind, input),
    target,
    scope: actionScopeLabel(kind, context, parsed),
    resultState,
    requestedChange: requestedChange(kind, input, parsed),
    previousState: previousState(kind, before),
    currentState: currentState(kind, after),
    clusterId,
    namespace,
    resourceName,
    generatedAt: displayValue(parsed.generated_at),
    followUpChecks: followUpChecks(kind, parsed, input, resultState, errorKind),
    errorKind,
    errorMessage,
    available: typeof parsed.available === "boolean" ? parsed.available : null,
    before
  }
}

function actionTarget(kind: ActionKind, parsed: Record<string, unknown>, input: Record<string, unknown>) {
  const name = displayValue(parsed.deployment) || displayValue(parsed.pod) || displayValue(parsed.node) || displayValue(input.name) || "-"
  const namespace = displayValue(parsed.namespace) || displayValue(input.namespace)
  if (kind === "set_node_cordon") return t("action_card_target_node", { name })
  if (kind === "delete_pod") return t("action_card_target_pod", { namespace: namespace || "-", name })
  return t("action_card_target_deployment", { namespace: namespace || "-", name })
}

function actionScopeLabel(kind: ActionKind, context: ToolCardContext, parsed: Record<string, unknown>) {
  const input = context.input || {}
  const cluster = displayValue(input.cluster_id)
  const namespace = displayValue(parsed.namespace) || displayValue(input.namespace)
  if (kind === "set_node_cordon") return cluster ? t("tool_card_scope_cluster", { cluster }) : t("tool_card_scope_all_clusters")
  if (cluster && namespace) return t("tool_card_scope_cluster_namespace", { cluster, namespace })
  if (cluster) return t("tool_card_scope_cluster", { cluster })
  return t("tool_card_scope_all_clusters")
}

function actionLabel(kind: ActionKind, input: Record<string, unknown>) {
  if (kind === "restart_rollout") return t("action_restart_rollout")
  if (kind === "scale_deployment") return t("action_scale_deployment")
  if (kind === "delete_pod") return t("action_delete_pod")
  return input.cordoned === false ? t("action_uncordon_node") : t("action_cordon_node")
}

function requestedChange(kind: ActionKind, input: Record<string, unknown>, parsed: Record<string, unknown>) {
  if (kind === "restart_rollout") return t("action_requested_restart_rollout")
  if (kind === "scale_deployment")
    return t("action_requested_scale", {
      replicas: displayValue(input.replicas) || displayValue((isPlainObject(parsed.after) ? parsed.after : {}).replicas) || "-"
    })
  if (kind === "delete_pod") return t("action_requested_delete_pod")
  const cordoned = input.cordoned === false ? false : isPlainObject(parsed.after) ? parsed.after.unschedulable === true : input.cordoned === true
  return cordoned ? t("action_requested_cordon") : t("action_requested_uncordon")
}

function previousState(kind: ActionKind, before: Record<string, unknown>) {
  if (kind === "restart_rollout") return t("action_state_restarted_at", { value: displayValue(before.restarted_at) || t("action_card_none") })
  if (kind === "scale_deployment") {
    const replicas = displayValue(before.replicas)
    return replicas === null ? null : t("action_state_replicas", { value: replicas })
  }
  if (kind === "delete_pod") return t("action_state_pod_phase", { value: displayValue(before.phase) || t("action_card_unknown") })
  if ("unschedulable" in before) return before.unschedulable === true ? t("action_state_unschedulable") : t("action_state_schedulable")
  return null
}

function currentState(kind: ActionKind, after: Record<string, unknown>) {
  if (kind === "restart_rollout") return t("action_state_restarted_at", { value: displayValue(after.restarted_at) || t("action_card_none") })
  if (kind === "scale_deployment") {
    const replicas = displayValue(after.replicas)
    return replicas === null ? null : t("action_state_replicas", { value: replicas })
  }
  if (kind === "delete_pod") return after.deleted === true ? t("action_state_deleted") : null
  if ("unschedulable" in after) return after.unschedulable === true ? t("action_state_unschedulable") : t("action_state_schedulable")
  return null
}

function actionNoOp(kind: ActionKind, before: Record<string, unknown>, after: Record<string, unknown>) {
  if (kind === "restart_rollout") return "restarted_at" in before && "restarted_at" in after && before.restarted_at === after.restarted_at
  if (kind === "scale_deployment") return "replicas" in before && "replicas" in after && before.replicas === after.replicas
  if (kind === "delete_pod") return false
  if (kind === "set_node_cordon") return before.unschedulable === after.unschedulable
  return false
}

function classifyActionError(message: string): ActionErrorKind {
  const normalized = message.toLowerCase()
  if (/(permission|forbidden|unauthorized|agentic access is disabled|write access is disabled|rbac)/.test(normalized)) return "permission"
  if (/(not found|was not found|404)/.test(normalized)) return "missing_resource"
  if (/(must be|required|invalid|non-negative|validation)/.test(normalized)) return "validation"
  return "api"
}

function actionStateLabel(state: ParsedActionCard["resultState"], errorKind: ActionErrorKind | null) {
  if (state === "succeeded") return t("action_state_succeeded")
  if (state === "no_op") return t("action_state_no_op")
  if (errorKind === "permission") return t("action_failure_permission")
  if (errorKind === "missing_resource") return t("action_failure_missing_resource")
  if (errorKind === "validation") return t("action_failure_validation")
  return t("action_failure_api")
}

function actionStateTone(card: ParsedActionCard) {
  if (card.resultState === "succeeded") return "success"
  if (card.resultState === "no_op") return "info"
  if (card.errorKind === "validation" || card.errorKind === "permission") return "warning"
  return "failure"
}

function actionErrorTitle(kind: ActionErrorKind | null) {
  if (kind === "permission") return t("action_error_permission_title")
  if (kind === "missing_resource") return t("action_error_missing_resource_title")
  if (kind === "validation") return t("action_error_validation_title")
  return t("action_error_api_title")
}

function followUpChecks(
  kind: ActionKind,
  parsed: Record<string, unknown>,
  input: Record<string, unknown>,
  state: ParsedActionCard["resultState"],
  errorKind: ActionErrorKind | null
) {
  if (state === "failed") {
    if (errorKind === "permission") return [t("action_followup_permission"), t("action_followup_list_clusters")]
    if (errorKind === "missing_resource") return [t("action_followup_refresh_resource"), t("action_followup_check_namespace")]
    if (errorKind === "validation") return [t("action_followup_fix_request"), t("action_followup_retry")]
    return [t("action_followup_api_health"), t("action_followup_events")]
  }

  if (kind === "restart_rollout") return [t("action_followup_rollout_status"), t("action_followup_deployment_pods")]
  if (kind === "scale_deployment") return [t("action_followup_deployment_ready"), t("action_followup_deployment_events")]
  if (kind === "delete_pod") return [t("action_followup_pod_recreated"), t("action_followup_pod_events")]

  const cordoned = input.cordoned === false ? false : isPlainObject(parsed.after) ? parsed.after.unschedulable === true : input.cordoned === true
  return cordoned
    ? [t("action_followup_node_unschedulable"), t("action_followup_pending_pods")]
    : [t("action_followup_node_schedulable"), t("action_followup_pending_pods")]
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
    if (isPlainObject(row)) return [kind === "secrets" ? secretMetadata(row) : summarizeRawResource(kind, row as K8sRow)]
    return null
  }
  const objectRows = rows.filter(isPlainObject) as K8sRow[]
  return kind === "secrets" ? objectRows.map(secretMetadata) : objectRows
}

function SecretDescribeBody({ card, secret }: { card: ParsedCard; secret: K8sRow }) {
  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-2xs font-semibold uppercase text-text-muted">{t("col_type")}</span>
        <StatePill state={displayValue(secret.type) || "-"} tone="neutral" />
      </div>
      <div className="grid gap-2 sm:grid-cols-3">
        <DetailRow label={t("col_name")} value={displayValue(secret.name) || "-"} />
        <DetailRow label={t("col_namespace")} value={displayValue(secret.namespace) || "-"} />
        <DetailRow label={t("col_keys")} value={String(numberValue(secret.key_count) ?? 0)} />
        <DetailRow label={t("col_immutable")} value={secret.immutable === true ? t("yes") : t("no")} />
        <DetailRow label={t("col_age")} value={formatAge(displayValue(secret.created_at))} />
      </div>
      <DetailRow label={t("col_owner_references")} value={arrayText(secret.owner_references)} />
      <DetailRow label={t("col_key_names")} value={arrayText(secret.key_names)} />
    </CardShell>
  )
}

function ConfigMapDescribeBody({ card, configMap }: { card: ParsedCard; configMap: K8sRow }) {
  const entries = configMapEntries(configMap)

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-3">
        <DetailRow label={t("col_name")} value={displayValue(configMap.name) || "-"} />
        <DetailRow label={t("col_namespace")} value={displayValue(configMap.namespace) || "-"} />
        <DetailRow label={t("col_keys")} value={String(entries.length)} />
      </div>
      {entries.length === 0 ? (
        <EmptyState>{t("config_map_no_keys")}</EmptyState>
      ) : (
        <div className="space-y-2">
          {entries.map((entry) => (
            <section
              className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface px-3 py-2"
              key={`${entry.binary ? "binary" : "text"}:${entry.name}`}
            >
              <div className="mb-2 flex min-w-0 flex-wrap items-center gap-2">
                <span className="break-all font-mono text-xs font-semibold text-text-primary">{entry.name}</span>
                {entry.binary ? <StatePill state={t("config_map_binary")} tone="neutral" /> : null}
                <span className="text-xs text-text-muted">{formatBytes(entry.bytes)}</span>
              </div>
              {entry.binary ? (
                <p className="text-xs text-text-muted">{t("config_map_binary_not_previewed")}</p>
              ) : (
                <TextPreview
                  maxChars={CONFIG_MAP_VALUE_PREVIEW_LIMIT}
                  maxLines={8}
                  modalLabel={t("config_map_value_for", { key: entry.name })}
                  text={entry.preview}
                />
              )}
              {entry.capped ? (
                <p className="mt-1 text-xs text-text-muted">{t("config_map_value_capped", { size: formatBytes(CONFIG_MAP_VALUE_DISPLAY_LIMIT) })}</p>
              ) : null}
            </section>
          ))}
        </div>
      )}
    </CardShell>
  )
}

function configMapEntries(configMap: K8sRow) {
  const data = isPlainObject(configMap.data) ? configMap.data : {}
  const binaryData = isPlainObject(configMap.binaryData) ? configMap.binaryData : {}
  const textEntries = Object.entries(data).map(([name, value]) => configMapEntry(name, value, false))
  const binaryEntries = Object.entries(binaryData).map(([name, value]) => configMapEntry(name, value, true))
  return [...textEntries, ...binaryEntries].sort((left, right) => left.name.localeCompare(right.name))
}

function configMapEntry(name: string, value: unknown, binary: boolean) {
  const raw = typeof value === "string" ? value : value == null ? "" : JSON.stringify(value)
  const encoded = new TextEncoder().encode(raw)
  const bytes = binary ? (base64DecodedSize(raw) ?? encoded.length) : encoded.length
  const capped = !binary && encoded.length > CONFIG_MAP_VALUE_DISPLAY_LIMIT
  const display = capped ? new TextDecoder().decode(encoded.slice(0, CONFIG_MAP_VALUE_DISPLAY_LIMIT)) : raw
  return { name, binary, bytes, capped, preview: redactToolCardText(display) }
}

function base64DecodedSize(value: string) {
  const normalized = value.replace(/\s/g, "")
  if (normalized.length === 0) return 0
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(normalized)) return null

  const padding = normalized.endsWith("==") ? 2 : normalized.endsWith("=") ? 1 : 0
  return (normalized.length / 4) * 3 - padding
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
  if (kind === "namespaces") return "namespace"
  if (kind === "nodes") return "node"
  if (kind === "pods") return "pod"
  if (kind === "pvcs") return "persistent_volume_claim"
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
  const items = Array.isArray(section.items) ? (section.items.filter(isPlainObject) as K8sRow[]) : []
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
  if (kind === "pods")
    return rows.filter((row) => !["Running", "Succeeded"].includes(displayValue(row.status) || "") || (numberValue(row.restart_count) ?? 0) > 0).length
  if (kind === "pvcs") return rows.filter((row) => displayValue(row.status) !== "Bound").length
  if (kind === "events") return rows.filter((row) => ["Warning", "Error"].includes(displayValue(row.type) || "")).length
  if (["deployments", "statefulsets"].includes(kind)) return rows.filter((row) => (numberValue(row.ready_replicas) ?? 0) < desiredReplicas(row)).length
  if (kind === "daemonsets") return rows.filter((row) => (numberValue(row.number_ready) ?? 0) < (numberValue(row.desired_number_scheduled) ?? 0)).length
  if (kind === "jobs")
    return rows.filter(
      (row) =>
        (numberValue(row.failed) ?? 0) > 0 ||
        ((numberValue(row.completions) ?? 0) > 0 && (numberValue(row.succeeded) ?? 0) < (numberValue(row.completions) ?? 0))
    ).length
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
      {
        key: "agentic_access_enabled",
        label: t("col_agentic_access"),
        render: (row) => (row.agentic_access_enabled === true ? t("agentic_enabled") : t("agentic_disabled")),
        tone: (row) => (row.agentic_access_enabled === true ? "success" : "warning")
      },
      {
        key: "allow_writes",
        label: t("col_allow_writes"),
        render: (row) => (row.allow_writes === true ? t("allow_writes_enabled") : t("allow_writes_disabled"))
      },
      { key: "updated_at", label: t("col_updated"), render: (row) => formatAge(displayValue(row.updated_at)) }
    ]
  }
  if (kind === "namespaces") {
    return [
      { key: "name", label: t("col_name") },
      { key: "status", label: t("col_status"), tone: (row) => (displayValue(row.status) === "Active" ? "success" : "warning") },
      { key: "labels", label: t("col_labels") },
      { key: "annotations", label: t("col_annotations") },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "nodes") {
    return [
      {
        key: "name",
        label: t("col_name"),
        render: (row) => <EntityReference kind="node" label={displayValue(row.name)} slug={displayValue(row.name)} />
      },
      {
        key: "ready",
        label: t("col_ready"),
        render: (row) => (row.ready === true ? t("node_ready") : t("node_not_ready")),
        tone: (row) => (row.ready === true ? "success" : "failure")
      },
      { key: "roles", label: t("col_roles"), render: (row) => arrayText(row.roles) },
      { key: "kubelet_version", label: t("col_kubelet") },
      { key: "internal_ip", label: t("col_internal_ip") },
      { key: "capacity", label: t("col_capacity"), render: (row) => nodeCapacity(row) },
      { key: "allocatable", label: t("col_allocatable"), render: (row) => nodeAllocatable(row) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "pods") {
    return [
      {
        key: "namespace",
        label: t("col_namespace"),
        render: (row) => <EntityReference kind="namespace" id={displayValue(row.cluster_id)} label={displayValue(row.namespace)} />
      },
      {
        key: "name",
        label: t("col_name"),
        render: (row) => <EntityReference kind="artifact" href={podLogsHref(row)} label={displayValue(row.name)} slug={podContext(row)} />
      },
      { key: "status", label: t("col_status"), tone: podTone },
      { key: "ready", label: t("col_ready") },
      { key: "restart_count", label: t("col_restarts"), tone: (row) => ((numberValue(row.restart_count) ?? 0) > 0 ? "warning" : "neutral") },
      { key: "pod_ip", label: t("col_pod_ip") },
      { key: "container_names", label: t("col_containers"), render: (row) => arrayText(row.container_names) },
      {
        key: "node_name",
        label: t("tool_card_node"),
        render: (row) => (
          <EntityReference
            kind="node"
            href={clusterResourceHref(row, "nodes", "node", row.node_name)}
            label={displayValue(row.node_name)}
            slug={displayValue(row.node_name)}
          />
        )
      },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "deployments") return workloadReplicaColumns("available_replicas")
  if (kind === "statefulsets") return workloadReplicaColumns("current_replicas")
  if (kind === "daemonsets") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      {
        key: "number_ready",
        label: t("col_ready"),
        render: (row) => `${numberValue(row.number_ready) ?? 0}/${numberValue(row.desired_number_scheduled) ?? 0}`,
        tone: (row) => ((numberValue(row.number_ready) ?? 0) >= (numberValue(row.desired_number_scheduled) ?? 0) ? "success" : "warning")
      },
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
      {
        key: "completions",
        label: t("col_completions"),
        render: (row) => `${numberValue(row.succeeded) ?? 0}/${numberValue(row.completions) ?? "-"}`,
        tone: (row) =>
          (numberValue(row.failed) ?? 0) > 0
            ? "failure"
            : (numberValue(row.completions) ?? 0) > 0 && (numberValue(row.succeeded) ?? 0) >= (numberValue(row.completions) ?? 0)
              ? "success"
              : "info"
      },
      { key: "parallelism", label: t("col_parallelism") },
      { key: "active_count", label: t("col_active") },
      { key: "failed", label: t("col_failed"), tone: (row) => ((numberValue(row.failed) ?? 0) > 0 ? "failure" : "neutral") },
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
      {
        key: "suspended",
        label: t("col_suspended"),
        render: (row) => (row.suspended === true ? t("yes") : t("no")),
        tone: (row) => (row.suspended === true ? "warning" : "success")
      },
      { key: "active_count", label: t("col_active") },
      { key: "last_schedule_time", label: t("col_last_seen"), render: (row) => formatAge(displayValue(row.last_schedule_time)) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "services") {
    return [
      {
        key: "namespace",
        label: t("col_namespace"),
        render: (row) => (
          <EntityReference
            kind="artifact"
            href={displayValue(row.cluster_id) ? `/k8s_clusters/${encodeURIComponent(displayValue(row.cluster_id) || "")}` : null}
            label={displayValue(row.namespace)}
            slug={displayValue(row.namespace)}
          />
        )
      },
      {
        key: "name",
        label: t("col_name"),
        render: (row) => <EntityReference kind="artifact" label={displayValue(row.name)} slug={serviceContext(row)} wrap="break" />
      },
      { key: "type", label: t("col_type") },
      { key: "cluster_ip", label: t("col_cluster_ip"), render: (row) => wrappedText(valueText(row.cluster_ip)) },
      { key: "external_ips", label: t("col_external_ips"), render: (row) => wrappedText(arrayText(row.external_ips)) },
      { key: "ports", label: t("col_ports"), render: (row) => wrappedText(portsText(row.ports)) },
      {
        key: "endpoints",
        label: t("col_endpoints"),
        render: (row) => wrappedText(endpointsText(row)),
        tone: (row) =>
          row.missing_target_warning === true || (numberValue(row.not_ready_addresses) ?? 0) > 0
            ? "warning"
            : (numberValue(row.ready_addresses) ?? 0) > 0
              ? "success"
              : "neutral"
      },
      { key: "selector", label: t("col_selector"), render: (row) => wrappedText(selectorText(row.selector)) },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "ingresses") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "hosts", label: t("col_hosts"), render: (row) => ingressHostLinks(row.hosts) },
      {
        key: "backend",
        label: t("col_backend"),
        render: (row) => <IngressBackendMappings row={row} />,
        tone: (row) => (ingressBackends(row).length === 0 ? "warning" : "neutral")
      },
      { key: "tls_hosts", label: t("col_tls"), render: (row) => ingressHostLinks(row.tls_hosts) },
      { key: "ingress_class", label: t("col_ingress_class") },
      { key: "load_balancer_addresses", label: t("col_load_balancer"), render: (row) => wrappedText(arrayText(row.load_balancer_addresses)) },
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
      ...(kind === "secrets"
        ? [
            { key: "immutable", label: t("col_immutable"), render: (row: K8sRow) => (row.immutable === true ? t("yes") : t("no")) },
            { key: "owner_references", label: t("col_owner_references"), render: (row: K8sRow) => arrayText(row.owner_references) }
          ]
        : []),
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  if (kind === "pvcs") {
    return [
      { key: "namespace", label: t("col_namespace") },
      { key: "name", label: t("col_name") },
      { key: "status", label: t("col_status"), tone: (row) => (displayValue(row.status) === "Bound" ? "success" : "warning") },
      { key: "capacity", label: t("col_capacity") },
      { key: "storage_class", label: t("col_storage_class") },
      { key: "access_modes", label: t("tool_card_access_modes"), render: (row) => arrayText(row.access_modes) },
      { key: "volume_name", label: t("col_volume_name") },
      { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
    ]
  }
  return [
    { key: "namespace", label: t("col_namespace") },
    { key: "type", label: t("col_type"), tone: (row) => (["Warning", "Error"].includes(displayValue(row.type) || "") ? "warning" : "success") },
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
    {
      key: "ready_replicas",
      label: t("col_ready"),
      render: (row) => `${numberValue(row.ready_replicas) ?? 0}/${desiredReplicas(row)}`,
      tone: (row) => ((numberValue(row.ready_replicas) ?? 0) >= desiredReplicas(row) ? "success" : "warning")
    },
    { key: currentKey, label: currentKey === "available_replicas" ? t("col_available") : t("col_current") },
    { key: "updated_replicas", label: t("col_updated") },
    { key: "selector", label: t("col_selector"), render: (row) => selectorText(row.selector) },
    { key: "conditions", label: t("col_conditions"), render: (row) => conditionsText(row.conditions) },
    { key: "created_at", label: t("col_age"), render: (row) => formatAge(displayValue(row.created_at)) }
  ]
}

function KubernetesTable({ columns, responsive = false, rows }: { columns: Column[]; responsive?: boolean; rows: K8sRow[] }) {
  return (
    <DataTable.Root
      className={responsive ? "block min-w-0 text-left text-xs sm:table sm:min-w-max" : "min-w-max text-left text-xs"}
      density="compact"
      wrapperClassName={responsive ? "overflow-visible sm:overflow-x-auto" : ""}
    >
      <DataTable.Header className={responsive ? "hidden sm:table-header-group" : ""}>
        <DataTable.Row>
          {columns.map((column) => (
            <DataTable.HeadCell className="px-2 py-1 text-2xs" key={column.key}>
              {column.label}
            </DataTable.HeadCell>
          ))}
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body className={responsive ? RESPONSIVE_TABLE_BODY_CLASSES : ""}>
        {rows.map((row, index) => (
          <DataTable.Row key={rowKey(row, index)}>
            {columns.map((column) => (
              <DataTable.Cell
                className={responsive ? RESPONSIVE_TABLE_CELL_CLASSES : "max-w-80 px-2 py-1 text-text-secondary"}
                data-label={responsive ? column.label : undefined}
                key={column.key}
              >
                {responsive ? <span className="text-2xs font-medium uppercase tracking-wide text-text-muted sm:hidden">{column.label}</span> : null}
                {cell(column, row)}
              </DataTable.Cell>
            ))}
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
  if (text)
    return (
      <span className="block truncate" title={text}>
        {text}
      </span>
    )
  return rendered
}

function SummaryStrip({ card }: { card: ParsedCard }) {
  return (
    <div className="grid gap-2 sm:grid-cols-3">
      <ScopeDetail card={card} />
      <DetailRow label={t("tool_card_resources")} value={card.countLabel} />
      <DetailRow
        label={t("tool_card_health")}
        value={card.warningCount > 0 ? t("tool_card_warning_count", { count: card.warningCount }) : t("tool_card_no_warnings")}
      />
      {card.generatedAt ? <DetailRow label={t("tool_card_generated_at")} value={card.generatedAt} /> : null}
    </div>
  )
}

function EventsBody({ card }: { card: ParsedCard }) {
  const [warningsOnly, setWarningsOnly] = useState(false)
  const rows = warningsOnly ? card.rows.filter(isWarningEvent) : card.rows

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-2xs text-text-muted">{t("event_filter_count", { shown: rows.length, total: card.rows.length })}</span>
        <Button onClick={() => setWarningsOnly((value) => !value)} size="sm" variant={warningsOnly ? "primary" : "secondary"}>
          {t("event_warnings_only")}
        </Button>
      </div>
      {rows.length > 0 ? (
        <div className="space-y-2">
          {rows.slice(0, ROW_LIMIT).map((row, index) => (
            <EventRow key={rowKey(row, index)} row={row} />
          ))}
        </div>
      ) : (
        <EmptyState>{t("event_no_warnings")}</EmptyState>
      )}
      {rows.length > ROW_LIMIT ? <InlineNotice>{t("tool_card_preview_limited", { shown: ROW_LIMIT, total: rows.length })}</InlineNotice> : null}
      {card.truncated ? <InlineNotice>{t("truncated_notice")}</InlineNotice> : null}
    </CardShell>
  )
}

function EventRow({ row }: { row: K8sRow }) {
  const eventName = displayValue(row.name)
  const eventType = displayValue(row.type) || "-"
  const reason = displayValue(row.reason) || "-"
  const message = displayValue(row.message) || "-"

  return (
    <article className="min-w-0 space-y-2 rounded border border-border bg-surface px-3 py-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={eventType} tone={isWarningEvent(row) ? "warning" : "success"} />
        <span className="min-w-0 break-words text-xs font-semibold text-text-primary">{reason}</span>
        {eventName ? <span className="break-all font-mono text-2xs text-text-muted">{eventName}</span> : null}
        <span className="ml-auto text-2xs text-text-muted">{t("event_count", { count: numberValue(row.count) ?? 0 })}</span>
      </div>
      <MarkdownPreview linkifyUrls maxChars={320} modalLabel={t("event_message_details")} text={message} />
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
        <DetailRow label={t("col_namespace")} value={displayValue(row.namespace) || "-"} />
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_object")}</div>
          {involvedObjectReference(row)}
        </div>
        <EventTimestamp label={t("col_first_seen")} value={displayValue(row.first_timestamp)} />
        <EventTimestamp label={t("col_last_seen")} value={displayValue(row.last_timestamp)} />
      </div>
    </article>
  )
}

function EventTimestamp({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="min-w-0" title={value || undefined}>
      <div className="text-2xs font-semibold uppercase text-text-muted">{label}</div>
      <div className="text-xs text-text-secondary">{value ? formatAge(value) : "-"}</div>
      {value ? <div className="break-all font-mono text-2xs text-text-muted">{value}</div> : null}
    </div>
  )
}

function isWarningEvent(row: K8sRow) {
  return ["Warning", "Error"].includes(displayValue(row.type) || "")
}

function NodeDescribeBody({ card, node }: { card: ParsedCard; node: K8sRow }) {
  const conditions = Array.isArray(node.conditions) ? (node.conditions.filter(isPlainObject) as K8sRow[]) : []

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_name")}</div>
          <EntityReference kind="node" label={displayValue(node.name)} slug={displayValue(node.name)} />
        </div>
        <DetailRow label={t("col_roles")} value={arrayText(node.roles)} />
        <DetailRow label={t("col_kubelet")} value={displayValue(node.kubelet_version) || "-"} />
        <DetailRow label={t("col_internal_ip")} value={displayValue(node.internal_ip) || "-"} />
        <DetailRow label={t("col_capacity")} value={nodeCapacity(node)} />
        <DetailRow label={t("col_allocatable")} value={nodeAllocatable(node)} />
        <DetailRow label={t("col_taints")} value={taintsText(node.taints)} />
        <DetailRow label={t("col_addresses")} value={addressesText(node.addresses)} />
        <DetailRow label={t("col_labels")} value={displayValue(node.labels) || "-"} />
        <DetailRow label={t("col_system_info")} value={systemInfoText(node.system_info)} />
        <DetailRow label={t("col_age")} value={formatAge(displayValue(node.created_at))} />
      </div>
      <div className="space-y-1">
        <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_conditions")}</div>
        {conditions.length > 0 ? (
          <KubernetesTable
            columns={[
              { key: "type", label: t("col_type") },
              { key: "status", label: t("col_status") },
              { key: "reason", label: t("col_reason") },
              { key: "message", label: t("col_message") }
            ]}
            rows={conditions}
          />
        ) : (
          <EmptyState>{t("node_no_conditions")}</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

function PodDescribeBody({ card, pod }: { card: ParsedCard; pod: K8sRow }) {
  const conditions = Array.isArray(pod.conditions) ? (pod.conditions.filter(isPlainObject) as K8sRow[]) : []
  const containers = Array.isArray(pod.containers) ? (pod.containers.filter(isPlainObject) as K8sRow[]) : []

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("logs_pod_label")}</div>
          <EntityReference kind="artifact" href={podLogsHref(pod)} label={displayValue(pod.name)} slug={podContext(pod)} />
        </div>
        <DetailRow label={t("col_status")} value={displayValue(pod.status) || "-"} />
        <DetailRow label={t("col_ready")} value={displayValue(pod.ready) || "-"} />
        <DetailRow label={t("col_pod_ip")} value={displayValue(pod.pod_ip) || "-"} />
        <DetailRow label={t("col_ips")} value={arrayText(pod.pod_ips)} />
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_node")}</div>
          <EntityReference
            kind="node"
            href={clusterResourceHref(pod, "nodes", "node", pod.node_name)}
            label={displayValue(pod.node_name)}
            slug={displayValue(pod.node_name)}
          />
        </div>
        <DetailRow label={t("col_owner_references")} value={arrayText(pod.owner_references)} />
        <DetailRow label={t("col_labels")} value={displayValue(pod.labels) || "-"} />
        <DetailRow label={t("col_age")} value={formatAge(displayValue(pod.created_at))} />
      </div>
      <div className="space-y-1">
        <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_containers")}</div>
        {containers.length > 0 ? (
          <KubernetesTable
            columns={[
              { key: "name", label: t("col_name") },
              { key: "image", label: t("col_image") },
              { key: "ready", label: t("col_ready"), render: (row) => (row.ready === true ? t("yes") : t("no")) },
              { key: "restart_count", label: t("col_restarts") },
              { key: "state", label: t("col_state") },
              { key: "last_state_reason", label: t("col_last_state_reason") }
            ]}
            rows={containers}
          />
        ) : (
          <EmptyState>{t("pod_no_containers")}</EmptyState>
        )}
      </div>
      <div className="space-y-1">
        <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_conditions")}</div>
        {conditions.length > 0 ? (
          <KubernetesTable
            columns={[
              { key: "type", label: t("col_type") },
              { key: "status", label: t("col_status") },
              { key: "reason", label: t("col_reason") },
              { key: "message", label: t("col_message") }
            ]}
            rows={conditions}
          />
        ) : (
          <EmptyState>{t("pod_no_conditions")}</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

function PvcDescribeBody({ card, pvc }: { card: ParsedCard; pvc: K8sRow }) {
  const conditions = Array.isArray(pvc.conditions) ? (pvc.conditions.filter(isPlainObject) as K8sRow[]) : []

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_name")}</div>
          <EntityReference kind="artifact" label={displayValue(pvc.name)} slug={pvcContext(pvc)} />
        </div>
        <DetailRow label={t("col_status")} value={displayValue(pvc.status) || "-"} />
        <DetailRow label={t("col_storage_class")} value={displayValue(pvc.storage_class) || "-"} />
        <DetailRow label={t("tool_card_access_modes")} value={arrayText(pvc.access_modes)} />
        <DetailRow label={t("col_requested_storage")} value={displayValue(pvc.requested_storage) || "-"} />
        <DetailRow label={t("col_capacity")} value={displayValue(pvc.capacity) || "-"} />
        <DetailRow label={t("col_volume_name")} value={displayValue(pvc.volume_name) || "-"} />
        <DetailRow label={t("col_age")} value={formatAge(displayValue(pvc.created_at))} />
      </div>
      <div className="space-y-1">
        <div className="text-2xs font-semibold uppercase text-text-muted">{t("col_conditions")}</div>
        {conditions.length > 0 ? (
          <KubernetesTable
            columns={[
              { key: "type", label: t("col_type") },
              { key: "status", label: t("col_status") },
              { key: "reason", label: t("col_reason") },
              { key: "message", label: t("col_message") }
            ]}
            rows={conditions}
          />
        ) : (
          <EmptyState>{t("pvc_no_conditions")}</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

function ScopeDetail({ card }: { card: ParsedCard }) {
  if (!card.clusterId) return <DetailRow label={t("tool_card_scope")} value={card.scope} />

  return (
    <div className="min-w-0">
      <div className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_scope")}</div>
      <div className="flex flex-wrap items-center gap-x-1 font-mono text-xs text-text-primary">
        <EntityReference kind="cluster" id={card.clusterId} label={t("tool_card_scope_cluster", { cluster: card.clusterId })} />
        {card.namespace ? (
          <>
            <span>/</span>
            <EntityReference kind="namespace" id={card.clusterId} label={card.namespace} />
          </>
        ) : null}
        {card.name ? (
          <>
            <span>/</span>
            {card.kind === "namespaces" ? (
              <EntityReference kind="namespace" id={card.clusterId} label={card.name} wrap="break" />
            ) : card.kind === "nodes" ? (
              <EntityReference kind="node" label={card.name} slug={card.name} wrap="break" />
            ) : (
              <span className="break-all">{card.name}</span>
            )}
          </>
        ) : null}
      </div>
    </div>
  )
}

function PodLogsBody({ card }: { card: ParsedCard }) {
  const row = card.rows[0] || {}
  const fullLog = redactToolCardText(displayValue(row.log) || "")
  const lines = logLines(fullLog)
  const requestedTailLines = numberValue(row.requested_tail_lines)

  return (
    <CardShell>
      <SummaryStrip card={card} />
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <div className="min-w-0">
          <div className="text-2xs font-semibold uppercase text-text-muted">{t("logs_pod_label")}</div>
          <EntityReference
            href={clusterResourceHref({ ...row, cluster_id: card.clusterId }, "logs", "pod", row.pod)}
            kind="artifact"
            label={displayValue(row.pod) || "-"}
            slug={[displayValue(row.namespace), displayValue(row.pod)].filter(Boolean).join("/")}
            wrap="break"
          />
        </div>
        <DetailRow label={t("col_namespace")} value={displayValue(row.namespace) || "-"} />
        <DetailRow label={t("logs_container_label")} value={displayValue(row.container) || t("tool_card_default_container")} />
        <DetailRow label={t("logs_requested_lines_label")} value={requestedTailLines === null ? "-" : String(requestedTailLines)} />
        <DetailRow label={t("logs_returned_lines_label")} value={String(lines.length)} />
        <DetailRow label={t("logs_previous_label")} value={row.previous === true ? t("yes") : t("no")} />
        <DetailRow label={t("logs_timestamps_label")} value={row.timestamps === true ? t("yes") : t("no")} />
      </div>
      {lines.length === 0 ? (
        <EmptyState>{t("logs_empty")}</EmptyState>
      ) : (
        <FilterableList emptyLabel={t("logs_search_no_matches")} itemText={(line) => line} items={lines} placeholder={t("logs_search_placeholder")}>
          {(visibleLines) => (
            <TextPreview fullText={fullLog} maxLines={80} modalLabel={t("logs_full_log_label")} text={visibleLines.join("\n")} truncate="tail" wrap={false} />
          )}
        </FilterableList>
      )}
    </CardShell>
  )
}

function OverviewBody({ card, overview }: { card: ParsedCard; overview: OverviewCard }) {
  return (
    <CardShell>
      <SummaryStrip card={card} />
      <OverviewSection clusterId={card.clusterId} kind="nodes" title={t("overview_node_usage")} section={overview.nodes} />
      <OverviewSection clusterId={card.clusterId} kind="pods" title={t("overview_pod_usage")} section={overview.pods} />
    </CardShell>
  )
}

function OverviewSection({ clusterId, kind, section, title }: { clusterId: string | null; kind: "nodes" | "pods"; section: OverviewSection; title: string }) {
  const [showAll, setShowAll] = useState(false)

  if (!section.available) {
    return (
      <div className="space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-semibold text-text-primary">{title}</span>
          <StatePill state={t("overview_unavailable")} tone="warning" />
        </div>
        <Notice tone="warning">{section.message || t("overview_metrics_unavailable")}</Notice>
        {section.reason ? <DetailRow label={t("overview_unavailable_reason")} value={section.reason} /> : null}
      </div>
    )
  }

  const rows: K8sRow[] = section.items.map((row) => ({ ...row, cluster_id: clusterId }))

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        <span className="font-semibold text-text-primary">{title}</span>
        <StatePill state={t("tool_card_resource_count", { count: section.items.length, resource: t("tool_card_items") })} tone="success" />
        <span className="text-text-muted">{formatMillicores(section.totalCpuMillicores)}</span>
        <span className="text-text-muted">{formatBytes(section.totalMemoryBytes)}</span>
      </div>
      {section.items.length > 0 ? (
        <FilterableList
          itemText={(row) =>
            [
              displayValue(row.namespace),
              displayValue(row.name),
              formatMillicores(numberValue(row.cpu_millicores) ?? 0),
              formatBytes(numberValue(row.memory_bytes) ?? 0)
            ]
              .filter(Boolean)
              .join(" ")
          }
          items={rows}
          placeholder={t("tool_card_filter_placeholder")}
        >
          {(visibleRows) => (
            <div className="space-y-2">
              <KubernetesTable columns={overviewColumns(kind)} responsive rows={showAll ? visibleRows : visibleRows.slice(0, ROW_LIMIT)} />
              {!showAll && visibleRows.length > ROW_LIMIT ? (
                <Button onClick={() => setShowAll(true)} size="sm" variant="secondary">
                  {t("overview_show_all_rows", { count: visibleRows.length })}
                </Button>
              ) : null}
            </div>
          )}
        </FilterableList>
      ) : (
        <EmptyState>{t("tool_card_empty", { resource: t("tool_card_items") })}</EmptyState>
      )}
    </div>
  )
}

function overviewColumns(kind: "nodes" | "pods"): Column[] {
  const nameColumn: Column = {
    key: "name",
    label: t("col_name"),
    render: (row) => (
      <EntityReference
        href={clusterResourceHref(row, kind, kind === "nodes" ? "node" : "pod", row.name)}
        kind={kind === "nodes" ? "node" : "artifact"}
        label={displayValue(row.name)}
        slug={kind === "pods" ? podContext(row) : displayValue(row.name)}
      />
    )
  }
  const usageColumns: Column[] = [
    { key: "cpu_millicores", label: t("col_cpu"), render: (row) => formatMillicores(numberValue(row.cpu_millicores) ?? 0) },
    { key: "memory_bytes", label: t("col_memory"), render: (row) => formatBytes(numberValue(row.memory_bytes) ?? 0) }
  ]
  if (kind === "nodes") return [nameColumn, ...usageColumns]

  return [
    {
      key: "namespace",
      label: t("col_namespace"),
      render: (row) => (
        <EntityReference href={clusterResourceHref(row, "pods")} kind="namespace" id={displayValue(row.cluster_id)} label={displayValue(row.namespace)} />
      )
    },
    nameColumn,
    ...usageColumns
  ]
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
  return [formatKubernetesCpu(cpu), formatKubernetesMemory(memory)].join(" / ")
}

function nodeAllocatable(row: K8sRow) {
  const cpu = displayValue(row.allocatable_cpu)
  const memory = displayValue(row.allocatable_memory)
  return [formatKubernetesCpu(cpu), formatKubernetesMemory(memory)].join(" / ")
}

function taintsText(value: unknown) {
  if (!Array.isArray(value)) return "-"
  return (
    value
      .filter(isPlainObject)
      .map(
        (taint) =>
          [displayValue(taint.key), displayValue(taint.value)].filter(Boolean).join("=") + (displayValue(taint.effect) ? `:${displayValue(taint.effect)}` : "")
      )
      .join(", ") || "-"
  )
}

function addressesText(value: unknown) {
  if (!Array.isArray(value)) return "-"
  return (
    value
      .filter(isPlainObject)
      .map((address) => [displayValue(address.type), displayValue(address.address)].filter(Boolean).join(": "))
      .join(", ") || "-"
  )
}

function systemInfoText(value: unknown) {
  if (!isPlainObject(value)) return "-"
  return (
    Object.entries(value)
      .map(([key, entry]) => `${key}: ${displayValue(entry) || "-"}`)
      .join(", ") || "-"
  )
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
  const parts = value
    .filter(isPlainObject)
    .slice(0, 3)
    .map((condition) => {
      const type = displayValue(condition.type)
      const status = displayValue(condition.status)
      const reason = displayValue(condition.reason)
      return [type, status, reason].filter(Boolean).join(":")
    })
  return parts.join(", ") || "-"
}

function portsText(value: unknown) {
  if (!Array.isArray(value)) return "-"
  return (
    value
      .filter(isPlainObject)
      .map((port) => {
        const portNumber = displayValue(port.port)
        const protocol = displayValue(port.protocol)
        const targetPort = displayValue(port.target_port) || displayValue(port.targetPort)
        return `${portNumber || "?"}${protocol ? `/${protocol}` : ""}${targetPort ? ` -> ${targetPort}` : ""}`
      })
      .join(", ") || "-"
  )
}

function endpointsText(row: K8sRow) {
  if (row.missing_target_warning === true) return t("tool_card_missing_targets")
  const ready = numberValue(row.ready_addresses)
  const notReady = numberValue(row.not_ready_addresses)
  if (ready == null && notReady == null) return "-"
  return t("services_endpoints_ready", { ready: ready ?? 0, total: (ready ?? 0) + (notReady ?? 0) })
}

function ingressBackends(row: K8sRow) {
  return ingressBackendMappings(row).map((mapping) => mapping.backend)
}

function ingressHostLinks(value: unknown) {
  if (!Array.isArray(value) || value.length === 0) return "-"
  return (
    <div className="flex flex-col items-start gap-1">
      {value.map((entry) => {
        const host = displayValue(entry)
        if (!host) return null
        return (
          <a className="break-all text-link hover:underline" href={`https://${host}`} key={host} rel="noopener noreferrer" target="_blank">
            {host}
          </a>
        )
      })}
    </div>
  )
}

function IngressBackendMappings({ row }: { row: K8sRow }) {
  const mappings = ingressBackendMappings(row)
  if (mappings.length === 0) return t("tool_card_missing_backend")
  return (
    <div className="flex min-w-0 flex-col gap-1 whitespace-normal sm:min-w-56">
      {mappings.map((mapping, index) => (
        <div className="grid grid-cols-1 gap-x-2 sm:grid-cols-[minmax(0,1fr)_auto]" key={`${mapping.host}-${mapping.path}-${index}`}>
          <span className="break-all font-mono">
            {mapping.host}
            {mapping.path} <span className="text-text-muted">({mapping.pathType})</span>
          </span>
          <span className="break-all font-mono sm:text-right">→ {mapping.backend}</span>
        </div>
      ))}
    </div>
  )
}

function ingressBackendMappings(row: K8sRow) {
  if (!Array.isArray(row.rules)) return []
  return row.rules.filter(isPlainObject).flatMap((rule) => {
    if (!Array.isArray(rule.paths)) return []
    const host = displayValue(rule.host) || "*"
    return rule.paths.filter(isPlainObject).flatMap((path) => {
      const service = isPlainObject(path.backend) && isPlainObject(path.backend.service) ? path.backend.service : null
      const servicePort = service && isPlainObject(service.port) ? service.port : null
      const serviceName = displayValue(path.service_name) || displayValue(service?.name)
      const port = displayValue(path.service_port) || displayValue(servicePort?.number) || displayValue(servicePort?.name)
      const backend = [serviceName, port].filter(Boolean).join(":")
      if (!backend) return []
      return [{ host, path: displayValue(path.path) || "/", pathType: displayValue(path.path_type) || displayValue(path.pathType) || "-", backend }]
    })
  })
}

function logLines(value: unknown) {
  const log = displayValue(value) ?? ""
  if (!log) return []

  const lines = log.split("\n")
  if (lines.at(-1) === "") lines.pop()
  return lines
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
  return rules.map((rule) => (isPlainObject(rule) ? rule.host : null)).filter(Boolean)
}

function tlsHosts(tls: unknown) {
  if (!Array.isArray(tls)) return []
  return tls.flatMap((entry) => (isPlainObject(entry) && Array.isArray(entry.hosts) ? entry.hosts : []))
}

function ingressLoadBalancerAddresses(loadBalancer: unknown) {
  if (!isPlainObject(loadBalancer) || !Array.isArray(loadBalancer.ingress)) return []
  return loadBalancer.ingress
    .filter(isPlainObject)
    .map((entry) => displayValue(entry.ip) || displayValue(entry.hostname))
    .filter((entry): entry is string => Boolean(entry))
}

function involvedObject(value: unknown) {
  if (!isPlainObject(value)) return "-"
  return [displayValue(value.kind), displayValue(value.name)].filter(Boolean).join(" / ") || "-"
}

function involvedObjectReference(row: K8sRow) {
  const object = isPlainObject(row.involved_object) ? row.involved_object : {}
  const kind = displayValue(object.kind)
  const name = displayValue(object.name)
  const label = [kind, name].filter(Boolean).join(" / ") || "-"
  const resource = kind ? EVENT_OBJECT_RESOURCES[kind] : null
  const href = resource ? clusterResourceHref(row, resource.tab, resource.key, name) : null

  return <EntityReference href={href} kind="artifact" label={label} slug={name || label} wrap="break" />
}

const EVENT_OBJECT_RESOURCES: Record<string, { tab: string; key: string }> = {
  Pod: { tab: "pods", key: "pod" },
  Node: { tab: "nodes", key: "node" },
  Deployment: { tab: "deployments", key: "deployment" }
}

function podTone(row: K8sRow) {
  const status = displayValue(row.status)
  if (status === "Running" || status === "Succeeded") return "success"
  if (status === "Pending") return "warning"
  return "failure"
}

function clusterResourceHref(row: K8sRow, tab: string, resourceKey?: string, resourceValue?: unknown) {
  const clusterId = displayValue(row.cluster_id)
  if (!clusterId) return null
  const search = new URLSearchParams({ tab })
  const namespace = displayValue(row.namespace)
  if (namespace) search.set("namespace", namespace)
  const value = displayValue(resourceValue)
  if (resourceKey && value) search.set(resourceKey, value)
  return `/k8s_clusters/${encodeURIComponent(clusterId)}?${search.toString()}`
}

function podLogsHref(row: K8sRow) {
  return clusterResourceHref(row, "logs", "pod", row.name)
}

function podContext(row: K8sRow) {
  return [displayValue(row.namespace), displayValue(row.name)].filter(Boolean).join("/") || null
}

function pvcContext(row: K8sRow) {
  return [displayValue(row.namespace), displayValue(row.name)].filter(Boolean).join("/") || null
}

function serviceContext(row: K8sRow) {
  return [displayValue(row.namespace), displayValue(row.name)].filter(Boolean).join("/") || null
}

function wrappedText(value: string) {
  return <span className="block whitespace-normal break-words">{value}</span>
}

function containerStateText(value: unknown) {
  if (!isPlainObject(value)) return "-"
  const [state, details] = Object.entries(value).find(([, entry]) => isPlainObject(entry)) || []
  if (!state || !isPlainObject(details)) return "-"
  const reason = displayValue(details.reason)
  return reason ? `${state}: ${reason}` : state
}

function containerStateReason(value: unknown) {
  if (!isPlainObject(value)) return "-"
  for (const details of Object.values(value)) {
    if (isPlainObject(details)) {
      const reason = displayValue(details.reason)
      if (reason) return reason
    }
  }
  return "-"
}

function rowKey(row: K8sRow, index: number) {
  return (
    [row.namespace, row.name, row.id, row.reason, row.last_timestamp]
      .map((part) => displayValue(part))
      .filter(Boolean)
      .join(":") || String(index)
  )
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

  if (kind === "namespaces")
    return {
      ...base,
      status: status.phase,
      labels: metadataKeysSummary(metadata.labels),
      annotations: metadataKeysSummary(metadata.annotations)
    }

  if (kind === "nodes") {
    const addresses = Array.isArray(status.addresses) ? status.addresses.filter(isPlainObject) : []
    const internalAddress = addresses.find((address) => displayValue(address.type) === "InternalIP")
    const capacity = isPlainObject(status.capacity) ? status.capacity : {}
    const allocatable = isPlainObject(status.allocatable) ? status.allocatable : {}
    const nodeInfo = isPlainObject(status.nodeInfo) ? status.nodeInfo : {}
    return {
      ...base,
      ready:
        Array.isArray(status.conditions) &&
        status.conditions.some((condition) => isPlainObject(condition) && condition.type === "Ready" && condition.status === "True"),
      roles: Object.keys(isPlainObject(metadata.labels) ? metadata.labels : {})
        .filter((key) => key.startsWith("node-role.kubernetes.io/"))
        .map((key) => key.replace("node-role.kubernetes.io/", "")),
      kubelet_version: nodeInfo.kubeletVersion,
      internal_ip: internalAddress?.address,
      capacity_cpu: capacity.cpu,
      capacity_memory: capacity.memory,
      allocatable_cpu: allocatable.cpu,
      allocatable_memory: allocatable.memory,
      taints: Array.isArray(spec.taints) ? spec.taints : [],
      addresses,
      labels: metadataKeysSummary(metadata.labels),
      system_info: nodeInfo
    }
  }

  if (kind === "pods") {
    const containerSpecs = Array.isArray(spec.containers) ? (spec.containers.filter(isPlainObject) as K8sRow[]) : []
    const containerStatuses = Array.isArray(status.containerStatuses) ? (status.containerStatuses.filter(isPlainObject) as K8sRow[]) : []
    const containers = containerSpecs.map((container) => {
      const containerStatus = containerStatuses.find((candidate) => displayValue(candidate.name) === displayValue(container.name)) || {}
      return {
        name: container.name,
        image: container.image,
        ready: containerStatus.ready === true,
        restart_count: numberValue(containerStatus.restartCount) ?? 0,
        state: containerStateText(containerStatus.state),
        last_state_reason: containerStateReason(containerStatus.lastState)
      }
    })
    const podIps = Array.isArray(status.podIPs)
      ? status.podIPs
          .filter(isPlainObject)
          .map((entry) => displayValue(entry.ip))
          .filter(Boolean)
      : []
    const owners = Array.isArray(metadata.ownerReferences)
      ? metadata.ownerReferences
          .filter(isPlainObject)
          .map((owner) => [displayValue(owner.kind), displayValue(owner.name)].filter(Boolean).join("/"))
          .filter(Boolean)
      : []
    return {
      ...base,
      status: status.phase,
      ready: `${containerStatuses.filter((entry) => entry.ready === true).length}/${containerStatuses.length}`,
      restart_count: containerStatuses.reduce((total, entry) => total + (numberValue(entry.restartCount) ?? 0), 0),
      node_name: spec.nodeName,
      pod_ip: status.podIP,
      pod_ips: podIps,
      container_names: containerSpecs.map((container) => displayValue(container.name)).filter(Boolean),
      containers,
      owner_references: owners,
      labels: metadataKeysSummary(metadata.labels)
    }
  }

  if (kind === "pvcs") {
    const resources = isPlainObject(spec.resources) ? spec.resources : {}
    const requests = isPlainObject(resources.requests) ? resources.requests : {}
    const capacity = isPlainObject(status.capacity) ? status.capacity : {}
    return {
      ...base,
      status: status.phase,
      storage_class: spec.storageClassName,
      access_modes: Array.isArray(spec.accessModes) ? spec.accessModes : [],
      requested_storage: requests.storage,
      capacity: capacity.storage,
      volume_name: spec.volumeName
    }
  }

  if (kind === "deployments")
    return {
      ...base,
      replicas: numberValue(spec.replicas),
      ready_replicas: numberValue(status.readyReplicas) ?? 0,
      available_replicas: numberValue(status.availableReplicas) ?? 0,
      updated_replicas: numberValue(status.updatedReplicas) ?? 0
    }
  if (kind === "statefulsets")
    return {
      ...base,
      replicas: numberValue(spec.replicas),
      ready_replicas: numberValue(status.readyReplicas) ?? 0,
      current_replicas: numberValue(status.currentReplicas) ?? 0,
      updated_replicas: numberValue(status.updatedReplicas) ?? 0
    }
  if (kind === "daemonsets")
    return {
      ...base,
      desired_number_scheduled: numberValue(status.desiredNumberScheduled) ?? 0,
      current_number_scheduled: numberValue(status.currentNumberScheduled) ?? 0,
      number_ready: numberValue(status.numberReady) ?? 0,
      number_available: numberValue(status.numberAvailable) ?? 0
    }
  if (kind === "jobs")
    return {
      ...base,
      completions: numberValue(spec.completions),
      parallelism: numberValue(spec.parallelism),
      active_count: numberValue(status.active) ?? 0,
      succeeded: numberValue(status.succeeded) ?? 0,
      failed: numberValue(status.failed) ?? 0
    }
  if (kind === "cronjobs")
    return {
      ...base,
      schedule: spec.schedule,
      suspended: spec.suspend === true,
      active_count: Array.isArray(status.active) ? status.active.length : 0,
      last_schedule_time: status.lastScheduleTime
    }
  if (kind === "services")
    return {
      ...base,
      type: spec.type,
      cluster_ip: spec.clusterIP,
      external_ips: Array.isArray(spec.externalIPs) ? spec.externalIPs : [],
      ports: Array.isArray(spec.ports) ? spec.ports : [],
      selector: spec.selector
    }
  if (kind === "ingresses")
    return {
      ...base,
      ingress_class: spec.ingressClassName,
      hosts: ingressHosts(spec.rules),
      rules: ingressRuleSummaries(spec.rules),
      tls_hosts: tlsHosts(spec.tls),
      load_balancer_addresses: ingressLoadBalancerAddresses(status.loadBalancer)
    }
  if (kind === "configmaps")
    return {
      ...base,
      data: isPlainObject(row.data) ? row.data : {},
      binaryData: isPlainObject(row.binaryData) ? row.binaryData : {},
      key_count: [...Object.keys(isPlainObject(row.data) ? row.data : {}), ...Object.keys(isPlainObject(row.binaryData) ? row.binaryData : {})].filter(
        (key, index, keys) => keys.indexOf(key) === index
      ).length,
      key_names: [...Object.keys(isPlainObject(row.data) ? row.data : {}), ...Object.keys(isPlainObject(row.binaryData) ? row.binaryData : {})]
        .filter((key, index, keys) => keys.indexOf(key) === index)
        .sort()
    }
  return row
}

// Keep this projection at the payload boundary: Secret values must never reach
// rendering or FilterableList's search index, even if a caller supplies a raw
// Kubernetes Secret instead of the server's metadata-only summary.
function secretMetadata(row: K8sRow): K8sRow {
  const metadata = isPlainObject(row.metadata) ? row.metadata : {}
  const source = Object.keys(metadata).length > 0 ? metadata : row
  const ownerReferences = Array.isArray(source.ownerReferences)
    ? source.ownerReferences
        .filter(isPlainObject)
        .map((owner) => [displayValue(owner.kind), displayValue(owner.name)].filter(Boolean).join("/"))
        .filter(Boolean)
    : Array.isArray(row.owner_references)
      ? row.owner_references.map(displayValue).filter(Boolean)
      : []
  const keyNames = Array.isArray(row.key_names)
    ? row.key_names.map(displayValue).filter((value): value is string => Boolean(value))
    : Object.keys(isPlainObject(row.data) ? row.data : {}).sort()

  return {
    name: source.name,
    namespace: source.namespace,
    type: row.type,
    key_count: numberValue(row.key_count) ?? keyNames.length,
    key_names: keyNames,
    immutable: row.immutable === true,
    owner_references: ownerReferences,
    created_at: source.creationTimestamp || row.created_at
  }
}

function metadataKeysSummary(value: unknown) {
  if (!isPlainObject(value)) return "-"
  const keys = Object.keys(value).sort()
  return keys.length > 0 ? `${keys.length}: ${keys.join(", ")}` : "-"
}

export function kubernetesToolCardExamples(toolName: K8sToolName): ToolCardExample[] {
  const kind = TOOL_KINDS[toolName]
  const input =
    kind === "clusters"
      ? {}
      : {
          cluster_id: 7,
          ...([
            "pods",
            "pvcs",
            "events",
            "deployments",
            "statefulsets",
            "daemonsets",
            "jobs",
            "cronjobs",
            "services",
            "ingresses",
            "configmaps",
            "pod_logs",
            "secrets"
          ].includes(kind)
            ? { namespace: "default" }
            : {}),
          ...(kind === "pod_logs" ? { name: "web-7d9b", tail_lines: 200 } : {})
        }
  return [
    { id: "healthy", label: "Healthy result", input, parsedResult: examplePayload(kind, "healthy") },
    { id: "warning_heavy", label: "Warning-heavy result", input, parsedResult: examplePayload(kind, "warning") },
    { id: "empty", label: "Empty result", input, parsedResult: examplePayload(kind, "empty") },
    { id: "error", label: "Error result", input, resultBody: "Error: Kubernetes cluster not found", resultError: true }
  ]
}

export function kubernetesActionToolCardExamples(toolName: K8sActionToolName): ToolCardExample[] {
  const kind = ACTION_KINDS[toolName]
  const examples: ToolCardExample[] = [
    { id: "successful_action", label: "Successful action", input: actionExampleInput(kind), parsedResult: actionExamplePayload(kind, "success") },
    {
      id: "validation_failure",
      label: "Validation failure",
      input: actionExampleInput(kind, "validation"),
      resultBody: "Error: replicas must be a non-negative integer",
      resultError: true
    },
    {
      id: "api_failure",
      label: "API failure",
      input: actionExampleInput(kind),
      resultBody: "Error: Kubeclient::HttpError: apiserver timed out",
      resultError: true
    },
    {
      id: "permission_denied",
      label: "Permission denied",
      input: actionExampleInput(kind),
      resultBody: "Error: Write access is disabled for Kubernetes cluster 7. Enable write access in K8s Cluster connection settings.",
      resultError: true
    }
  ]
  if (kind !== "delete_pod")
    examples.splice(1, 0, { id: "no_op", label: "No-op action", input: actionExampleInput(kind), parsedResult: actionExamplePayload(kind, "noop") })
  return examples
}

export function kubernetesKubectlToolCardExamples(_toolName: K8sKubectlToolName): ToolCardExample[] {
  return [
    {
      id: "successful_get",
      label: "Successful get",
      input: { credential: "prod-k3s", kube_context: "prod", namespace: "default", args: ["get", "pods"] },
      parsedResult: {
        ok: true,
        status: 0,
        stdout: { text: "NAME READY STATUS\nweb 1/1 Running\n", truncated: false },
        stderr: { text: "", truncated: false },
        command: { executable: "kubectl", args: ["--context", "prod", "--namespace", "default", "get", "pods"] },
        target: { kube_context: "prod", kube_namespace: "default" },
        credential: { credential_id: 12, credential_name: "prod-k3s", credential_type: "k8s_cluster.kubeconfig" },
        safe_metadata: { cluster: "production", context: "prod", host: "kube.example.test" }
      }
    },
    {
      id: "policy_denied",
      label: "Policy denied",
      input: { credential: "prod-k3s", kube_context: "prod", args: ["get", "secrets", "-o", "yaml"] },
      parsedResult: {
        ok: false,
        status: 1,
        stdout: { text: "", truncated: false },
        stderr: { text: "Error from server (Forbidden): secrets is forbidden by cluster policy", truncated: false },
        command: { executable: "kubectl", args: ["--context", "prod", "get", "secrets", "-o", "yaml"] },
        target: { kube_context: "prod" },
        credential: { credential_id: 12, credential_name: "prod-k3s", credential_type: "k8s_cluster.kubeconfig" },
        safe_metadata: { cluster: "production", context: "prod", host: "kube.example.test" }
      },
      resultError: true
    }
  ]
}

function actionExampleInput(kind: ActionKind, variant: "success" | "validation" = "success") {
  if (kind === "restart_rollout") return { cluster_id: 7, namespace: "default", name: "web" }
  if (kind === "scale_deployment") return { cluster_id: 7, namespace: "default", name: "web", replicas: variant === "validation" ? -1 : 5 }
  if (kind === "delete_pod") return { cluster_id: 7, namespace: "default", name: "web-7d9b" }
  return { cluster_id: 7, name: "node-1", cordoned: true }
}

function actionExamplePayload(kind: ActionKind, variant: "success" | "noop") {
  const generated_at = "2026-09-30T12:00:00Z"
  if (kind === "restart_rollout") {
    return {
      available: true,
      generated_at,
      deployment: "web",
      namespace: "default",
      before: { restarted_at: variant === "noop" ? "2026-09-30T11:00:00Z" : null },
      after: { restarted_at: "2026-09-30T11:00:00Z" }
    }
  }
  if (kind === "scale_deployment") {
    return {
      available: true,
      generated_at,
      deployment: "web",
      namespace: "default",
      before: { replicas: variant === "noop" ? 5 : 2 },
      after: { replicas: 5 }
    }
  }
  if (kind === "delete_pod") {
    return {
      available: true,
      generated_at,
      pod: "web-7d9b",
      namespace: "default",
      before: { node_name: "node-1", phase: "Running", restart_count: 2, owner_kind: "ReplicaSet", owner_name: "web-7d9b" },
      after: { deleted: true }
    }
  }
  return {
    available: true,
    generated_at,
    node: "node-1",
    before: { unschedulable: variant === "noop" },
    after: { unschedulable: true },
    audit_id: "k8s-audit-123"
  }
}

function examplePayload(kind: CardKind, variant: "healthy" | "warning" | "empty") {
  if (kind === "overview") return overviewExample(variant)
  if (kind === "clusters")
    return {
      clusters:
        variant === "empty"
          ? []
          : [{ id: 7, label: "Production", agentic_access_enabled: variant !== "warning", allow_writes: false, updated_at: "2026-09-30T12:00:00Z" }]
    }
  if (kind === "namespaces")
    return {
      available: true,
      truncated: false,
      namespaces: variant === "empty" ? [] : [{ name: "default", status: variant === "warning" ? "Terminating" : "Active", created_at: "2026-09-01T12:00:00Z" }]
    }
  if (kind === "nodes")
    return {
      available: true,
      truncated: false,
      nodes:
        variant === "empty"
          ? []
          : [
              {
                name: "node-1",
                ready: variant !== "warning",
                roles: ["control-plane"],
                capacity_cpu: "4",
                capacity_memory: "16Gi",
                created_at: "2026-09-01T12:00:00Z"
              }
            ]
    }
  if (kind === "pods")
    return {
      available: true,
      truncated: variant === "warning",
      pods:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "web-7d9b",
                status: variant === "warning" ? "CrashLoopBackOff" : "Running",
                ready: variant === "warning" ? "0/1" : "1/1",
                restart_count: variant === "warning" ? 14 : 0,
                node_name: "node-1",
                created_at: "2026-09-30T10:00:00Z"
              }
            ]
    }
  if (kind === "pvcs")
    return {
      available: true,
      truncated: false,
      persistent_volume_claims:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "data-postgres-0",
                status: variant === "warning" ? "Pending" : "Bound",
                capacity: "20Gi",
                storage_class: "fast",
                access_modes: ["ReadWriteOnce"],
                created_at: "2026-09-10T12:00:00Z"
              }
            ]
    }
  if (kind === "deployments")
    return {
      available: true,
      truncated: variant === "warning",
      deployments:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "web",
                replicas: 3,
                ready_replicas: variant === "warning" ? 1 : 3,
                available_replicas: variant === "warning" ? 1 : 3,
                updated_replicas: variant === "warning" ? 2 : 3,
                selector: { app: "web" },
                conditions: [
                  {
                    type: "Available",
                    status: variant === "warning" ? "False" : "True",
                    reason: variant === "warning" ? "MinimumReplicasUnavailable" : "MinimumReplicasAvailable"
                  }
                ],
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "statefulsets")
    return {
      available: true,
      truncated: false,
      stateful_sets:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "postgres",
                replicas: 3,
                ready_replicas: variant === "warning" ? 2 : 3,
                current_replicas: 3,
                updated_replicas: variant === "warning" ? 2 : 3,
                selector: { app: "postgres" },
                conditions: [{ type: "Available", status: variant === "warning" ? "False" : "True" }],
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "daemonsets")
    return {
      available: true,
      truncated: false,
      daemon_sets:
        variant === "empty"
          ? []
          : [
              {
                namespace: "kube-system",
                name: "node-agent",
                desired_number_scheduled: 4,
                current_number_scheduled: 4,
                number_ready: variant === "warning" ? 3 : 4,
                number_available: variant === "warning" ? 3 : 4,
                selector: { app: "node-agent" },
                conditions: [{ type: "Available", status: variant === "warning" ? "False" : "True" }],
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "jobs")
    return {
      available: true,
      truncated: false,
      jobs:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "migrate",
                completions: 1,
                parallelism: 1,
                active_count: variant === "warning" ? 0 : 0,
                succeeded: variant === "warning" ? 0 : 1,
                failed: variant === "warning" ? 1 : 0,
                selector: { "job-name": "migrate" },
                conditions: [{ type: variant === "warning" ? "Failed" : "Complete", status: "True" }],
                created_at: "2026-09-30T11:00:00Z"
              }
            ]
    }
  if (kind === "cronjobs")
    return {
      available: true,
      truncated: false,
      cron_jobs:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "nightly",
                schedule: "0 2 * * *",
                suspended: variant === "warning",
                active_count: 0,
                last_schedule_time: "2026-09-30T02:00:00Z",
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "services")
    return {
      available: true,
      truncated: false,
      services:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "web",
                type: "ClusterIP",
                cluster_ip: "10.0.0.10",
                external_ips: [],
                ports: [{ name: "http", port: 80, target_port: 8080, protocol: "TCP" }],
                selector: { app: "web" },
                ready_addresses: variant === "warning" ? 0 : 2,
                not_ready_addresses: variant === "warning" ? 1 : 0,
                missing_target_warning: variant === "warning",
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "ingresses")
    return {
      available: true,
      truncated: false,
      ingresses:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "web",
                ingress_class: "nginx",
                hosts: ["app.example.test"],
                rules:
                  variant === "warning"
                    ? []
                    : [{ host: "app.example.test", paths: [{ path: "/", path_type: "Prefix", service_name: "web", service_port: 80 }] }],
                tls_hosts: variant === "warning" ? [] : ["app.example.test"],
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "configmaps")
    return {
      available: true,
      truncated: false,
      config_maps:
        variant === "empty"
          ? []
          : [{ namespace: "default", name: "web-config", key_count: 2, key_names: ["LOG_LEVEL", "PUBLIC_URL"], created_at: "2026-09-20T12:00:00Z" }]
    }
  if (kind === "secrets")
    return {
      available: true,
      truncated: false,
      secrets:
        variant === "empty"
          ? []
          : [
              {
                namespace: "default",
                name: "web-secret",
                type: "Opaque",
                key_count: 2,
                key_names: ["API_TOKEN", "DATABASE_URL"],
                created_at: "2026-09-20T12:00:00Z"
              }
            ]
    }
  if (kind === "pod_logs")
    return {
      available: true,
      generated_at: "2026-09-30T12:00:00Z",
      pod: "web-7d9b",
      namespace: "default",
      container: "web",
      log:
        variant === "empty"
          ? ""
          : [
              `2026-09-30T12:00:00Z boot complete`,
              variant === "warning" ? "2026-09-30T12:00:02Z ERROR database timeout" : "2026-09-30T12:00:02Z request complete"
            ].join("\n")
    }
  return {
    available: true,
    truncated: variant === "warning",
    events:
      variant === "empty"
        ? []
        : [
            {
              namespace: "default",
              type: variant === "warning" ? "Warning" : "Normal",
              reason: variant === "warning" ? "FailedScheduling" : "Pulled",
              message: variant === "warning" ? "0/3 nodes are available" : "Container image pulled",
              involved_object: { kind: "Pod", name: "web-7d9b" },
              count: variant === "warning" ? 8 : 1,
              last_timestamp: "2026-09-30T12:00:00Z"
            }
          ]
  }
}

function overviewExample(variant: "healthy" | "warning" | "empty") {
  const empty = variant === "empty"
  return {
    generated_at: "2026-09-30T12:00:00Z",
    nodes:
      variant === "warning"
        ? { available: false, reason: "metrics_unavailable", message: "metrics.k8s.io is not available" }
        : {
            available: true,
            items: empty ? [] : [{ name: "node-1", cpu_millicores: 840, memory_bytes: 8_589_934_592 }],
            total_cpu_millicores: empty ? 0 : 840,
            total_memory_bytes: empty ? 0 : 8_589_934_592
          },
    pods: {
      available: true,
      items: empty ? [] : [{ namespace: "default", name: "web-7d9b", cpu_millicores: 120, memory_bytes: 268_435_456 }],
      total_cpu_millicores: empty ? 0 : 120,
      total_memory_bytes: empty ? 0 : 268_435_456
    }
  }
}

import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { CardShell, displayValue, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for explain_stuck_job (the Tier 1 tool-card work). Leads
// with the Job, stuck flag, recommended action, and human summary, then puts
// the deep diagnostic sections (Workflows, Runs, Dependencies, Landing,
// WorkUnits) behind collapsible <details> so the card stays scannable.
type RecommendedAction = { action: string; reason: string | null }

type ExplainStuckJobCard = {
  jobId: string
  slug: string | null
  title: string | null
  state: string
  stuck: boolean
  recommendedAction: RecommendedAction | null
  humanSummary: string | null
  workflowsSummary: string | null
  runsSummary: string | null
  dependenciesSummary: string | null
  landingSummary: string | null
  workUnitsSummary: string | null
}

function arrayLength(value: unknown): number {
  return Array.isArray(value) ? value.length : 0
}

function parseRecommendedAction(value: unknown): RecommendedAction | null {
  if (!isPlainObject(value)) return null
  const action = displayValue(value.action)
  if (!action) return null
  return { action, reason: displayValue(value.reason) }
}

function workflowsSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const latest = isPlainObject(value.latest) ? value.latest : null
  const bits = [
    latest
      ? i18n.t("chat:tool_card_stuck_latest_workflow", {
          state: displayValue(latest.state) ?? i18n.t("chat:unknown"),
          trigger: displayValue(latest.trigger_kind) ?? i18n.t("chat:unknown")
        })
      : i18n.t("chat:tool_card_stuck_no_workflows"),
    i18n.t("chat:tool_card_stuck_active_count", { count: arrayLength(value.active) }),
    i18n.t("chat:tool_card_stuck_queued_count", { count: arrayLength(value.queued) }),
    i18n.t("chat:tool_card_stuck_failed_count", { count: arrayLength(value.failed) })
  ]
  return bits.join(" · ")
}

function runsSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const staleHeartbeats = Array.isArray(value.heartbeat) ? value.heartbeat.filter((entry) => isPlainObject(entry) && entry.stale_for_admin === true).length : 0
  const bits = [
    i18n.t("chat:tool_card_stuck_active_count", { count: arrayLength(value.active) }),
    i18n.t("chat:tool_card_stuck_failed_count", { count: arrayLength(value.failed) }),
    staleHeartbeats > 0 ? i18n.t("chat:tool_card_stuck_heartbeat_count", { count: staleHeartbeats }) : null
  ].filter((bit): bit is string => Boolean(bit))
  return bits.join(" · ")
}

function dependenciesSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const bits = [
    i18n.t("chat:tool_card_stuck_pending_count", { count: arrayLength(value.pending) }),
    i18n.t("chat:tool_card_stuck_unsatisfied_count", { count: arrayLength(value.unsatisfied) }),
    i18n.t("chat:tool_card_stuck_leaf_blocker_count", { count: arrayLength(value.multiple_leaf_dependencies) }),
    i18n.t("chat:tool_card_stuck_redundant_count", { count: arrayLength(value.redundant_transitive_dependencies) })
  ]
  return bits.join(" · ")
}

function landingSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const mergeability = isPlainObject(value.mergeability) ? value.mergeability : null
  const bits = [
    mergeability?.github_state != null ? i18n.t("chat:tool_card_stuck_github_state", { state: displayValue(mergeability.github_state) }) : null,
    mergeability?.local_state != null ? i18n.t("chat:tool_card_stuck_local_state", { state: displayValue(mergeability.local_state) }) : null,
    isPlainObject(value.pr_checks) && value.pr_checks.state != null
      ? i18n.t("chat:tool_card_stuck_checks", { state: displayValue(value.pr_checks.state) })
      : null,
    typeof value.commits_behind_base === "number" ? i18n.t("chat:tool_card_stuck_behind_count", { count: value.commits_behind_base }) : null,
    displayValue(value.landing_failure_reason) ? i18n.t("chat:tool_card_stuck_failure", { reason: displayValue(value.landing_failure_reason) }) : null
  ].filter((bit): bit is string => Boolean(bit))
  return bits.length > 0 ? bits.join(" · ") : i18n.t("chat:tool_card_stuck_no_landing")
}

function workUnitsSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  return `${i18n.t("chat:tool_card_stuck_active_count", { count: arrayLength(value.active) })} · ${i18n.t("chat:tool_card_stuck_recent_count", { count: arrayLength(value.recent) })}`
}

function parseExplainStuckJob(context: ToolCardContext): ExplainStuckJobCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null

  const job = parsed.job
  const jobId = displayValue(job.id)
  const state = displayValue(job.state)
  if (!jobId || !state) return null

  return {
    jobId,
    slug: displayValue(job.slug),
    title: displayValue(job.issue_title ?? job.title),
    state,
    stuck: parsed.stuck === true,
    recommendedAction: parseRecommendedAction(parsed.recommended_action),
    humanSummary: displayValue(parsed.human_summary),
    workflowsSummary: workflowsSummary(parsed.workflows),
    runsSummary: runsSummary(parsed.runs),
    dependenciesSummary: dependenciesSummary(parsed.dependencies),
    landingSummary: landingSummary(parsed.landing),
    workUnitsSummary: workUnitsSummary(parsed.work_units)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseExplainStuckJob(context)
  if (!card) return null
  return i18n.t(card.stuck ? "chat:tool_card_stuck_summary" : "chat:tool_card_not_stuck_summary", { job: card.slug || `JOB-${card.jobId}` })
}

function DetailSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
        {label}
      </summary>
      <div className="mt-1 text-gray-700 dark:text-gray-300">{children}</div>
    </details>
  )
}

function hasDiagnostics(card: ExplainStuckJobCard) {
  return Boolean(card.workflowsSummary || card.runsSummary || card.dependenciesSummary || card.landingSummary || card.workUnitsSummary)
}

function renderExpanded(context: ToolCardContext) {
  const card = parseExplainStuckJob(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{card.slug || `JOB-${card.jobId}`}</span>
        <StatePill state={card.state} />
        <StatePill state={card.stuck ? i18n.t("chat:tool_card_stuck") : i18n.t("chat:tool_card_not_stuck")} tone={card.stuck ? "failure" : "success"} />
      </div>
      {card.title ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{card.title}</div> : null}
      {card.recommendedAction ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label={i18n.t("chat:tool_card_stuck_recommended_action")} value={card.recommendedAction.action.replace(/_/g, " ")} />
          {card.recommendedAction.reason ? <Row label={i18n.t("chat:tool_card_stuck_reason")} value={card.recommendedAction.reason} /> : null}
        </dl>
      ) : null}
      {card.humanSummary ? <div className="text-gray-600 dark:text-gray-400">{card.humanSummary}</div> : null}
      {hasDiagnostics(card) ? (
        <div className="space-y-1">
          <SectionLabel>{i18n.t("chat:tool_card_stuck_diagnostics")}</SectionLabel>
          {card.workflowsSummary ? <DetailSection label={i18n.t("chat:tool_card_stuck_workflows")}>{card.workflowsSummary}</DetailSection> : null}
          {card.runsSummary ? <DetailSection label={i18n.t("chat:tool_card_stuck_runs")}>{card.runsSummary}</DetailSection> : null}
          {card.dependenciesSummary ? <DetailSection label={i18n.t("chat:tool_card_stuck_dependencies")}>{card.dependenciesSummary}</DetailSection> : null}
          {card.landingSummary ? <DetailSection label={i18n.t("chat:tool_card_stuck_landing")}>{card.landingSummary}</DetailSection> : null}
          {card.workUnitsSummary ? <DetailSection label={i18n.t("chat:tool_card_stuck_work_units")}>{card.workUnitsSummary}</DetailSection> : null}
        </div>
      ) : null}
    </CardShell>
  )
}

const explainStuckJobToolCard: ToolCardRenderer = {
  toolName: "explain_stuck_job",
  collapsedSummary,
  renderExpanded
}

export default explainStuckJobToolCard

import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for explain_stuck_job (EPIC-291 / JOB-4221). Leads
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
    latest ? `latest ${displayValue(latest.state) ?? "unknown"} (${displayValue(latest.trigger_kind) ?? "unknown"})` : "no workflows yet",
    `${arrayLength(value.active)} active`,
    `${arrayLength(value.queued)} queued`,
    `${arrayLength(value.failed)} failed`
  ]
  return bits.join(" · ")
}

function runsSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const staleHeartbeats = Array.isArray(value.heartbeat) ? value.heartbeat.filter((entry) => isPlainObject(entry) && entry.stale_for_admin === true).length : 0
  const bits = [
    `${arrayLength(value.active)} active`,
    `${arrayLength(value.failed)} failed`,
    staleHeartbeats > 0 ? `${staleHeartbeats} stale heartbeat${staleHeartbeats === 1 ? "" : "s"}` : null
  ].filter((bit): bit is string => Boolean(bit))
  return bits.join(" · ")
}

function dependenciesSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const bits = [
    `${arrayLength(value.pending)} pending`,
    `${arrayLength(value.unsatisfied)} unsatisfied`,
    `${arrayLength(value.multiple_leaf_dependencies)} leaf blockers`,
    `${arrayLength(value.redundant_transitive_dependencies)} redundant`
  ]
  return bits.join(" · ")
}

function landingSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const mergeability = isPlainObject(value.mergeability) ? value.mergeability : null
  const bits = [
    mergeability?.github_state != null ? `GitHub: ${displayValue(mergeability.github_state)}` : null,
    mergeability?.local_state != null ? `local: ${displayValue(mergeability.local_state)}` : null,
    isPlainObject(value.pr_checks) && value.pr_checks.state != null ? `checks: ${displayValue(value.pr_checks.state)}` : null,
    typeof value.commits_behind_base === "number" ? `${value.commits_behind_base} commits behind base` : null,
    displayValue(value.landing_failure_reason) ? `failure: ${displayValue(value.landing_failure_reason)}` : null
  ].filter((bit): bit is string => Boolean(bit))
  return bits.length > 0 ? bits.join(" · ") : "no landing activity"
}

function workUnitsSummary(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  return `${arrayLength(value.active)} active · ${arrayLength(value.recent)} recent`
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
  return `${card.slug || `JOB-${card.jobId}`}: ${card.stuck ? "stuck" : "not stuck"}`
}

function DetailSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">{label}</summary>
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
        <StatePill state={card.stuck ? "stuck" : "not stuck"} tone={card.stuck ? "failure" : "success"} />
      </div>
      {card.title ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{card.title}</div> : null}
      {card.recommendedAction ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Recommended action" value={card.recommendedAction.action.replace(/_/g, " ")} />
          {card.recommendedAction.reason ? <Row label="Reason" value={card.recommendedAction.reason} /> : null}
        </dl>
      ) : null}
      {card.humanSummary ? <div className="text-gray-600 dark:text-gray-400">{card.humanSummary}</div> : null}
      {hasDiagnostics(card) ? (
        <div className="space-y-1">
          <SectionLabel>Diagnostics</SectionLabel>
          {card.workflowsSummary ? <DetailSection label="Workflows">{card.workflowsSummary}</DetailSection> : null}
          {card.runsSummary ? <DetailSection label="Runs">{card.runsSummary}</DetailSection> : null}
          {card.dependenciesSummary ? <DetailSection label="Dependencies">{card.dependenciesSummary}</DetailSection> : null}
          {card.landingSummary ? <DetailSection label="Landing">{card.landingSummary}</DetailSection> : null}
          {card.workUnitsSummary ? <DetailSection label="Work units">{card.workUnitsSummary}</DetailSection> : null}
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

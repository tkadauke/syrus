import { type ReactNode } from "react"
import { Badge, CardShell, displayValue, EntityReference, SectionLabel, StatePill } from "./toolCardUi"

// Shared parsing/rendering for the core proposal tools (propose_job,
// propose_epic, list_proposals, delete_proposal) — the pending-action tool-card work.
// Lives outside tool_cards/ for the same reason as toolCardUi.tsx: the
// pluginToolCards.tsx directory glob treats every non-test .tsx under
// tool_cards/ as a card module and would warn about a missing default
// export. propose_epic_with_jobs has its own, differently-shaped payload
// (no title, a child_jobs list of proposals rather than a materialized
// result) and is handled by its own tool_cards/propose_epic_with_jobs.tsx.
export type MaterializedOutcome =
  | { kind: "job"; jobId: string; jobState: string | null }
  | { kind: "epic"; epicId: string; childJobCount: number }
  | { kind: "rejected"; reason: string }
  | null

export type ProposalOutcome = {
  slug: string
  title: string | null
  kind: string
  state: string
  repository: string | null
  dependencyCount: number
  targetEpicId: string | null
  targetEpicLabel: string | null
  providerSetting: string | null
  materialized: MaterializedOutcome
}

function parseMaterialized(value: unknown): MaterializedOutcome {
  if (!isPlainObject(value)) return null
  const kind = displayValue(value.kind)

  if (kind === "job") {
    const jobId = displayValue(value.job_id)
    return jobId ? { kind: "job", jobId, jobState: displayValue(value.job_state) } : null
  }

  if (kind === "epic") {
    const epicId = displayValue(value.epic_id)
    if (!epicId) return null
    const childJobCount = Array.isArray(value.child_jobs) ? value.child_jobs.length : 0
    return { kind: "epic", epicId, childJobCount }
  }

  if (kind === "rejected") {
    const reason = displayValue(value.reason)
    return reason ? { kind: "rejected", reason } : null
  }

  return null
}

export function parseProposalOutcome(value: unknown): ProposalOutcome | null {
  if (!isPlainObject(value)) return null
  const slug = displayValue(value.slug)
  const state = displayValue(value.state)
  if (!slug || !state) return null

  return {
    slug,
    title: displayValue(value.title),
    kind: displayValue(value.kind) || "job",
    state,
    repository: displayValue(value.repository),
    dependencyCount: Array.isArray(value.dependencies) ? value.dependencies.length : 0,
    targetEpicId: isPlainObject(value.target_epic) ? displayValue(value.target_epic.id) : null,
    targetEpicLabel: isPlainObject(value.target_epic) ? displayValue(value.target_epic.label) : null,
    providerSetting: displayValue(value.provider_setting),
    materialized: parseMaterialized(value.materialized)
  }
}

function humanizeKind(kind: string): string {
  return kind.includes("epic") ? "Epic" : "Job"
}

export function proposalOutcomeSummary(proposal: ProposalOutcome): string {
  const label = proposal.title || proposal.slug
  return `${humanizeKind(proposal.kind)} proposal: ${label} (${proposal.state})`
}

function MaterializedOutcomeDetail({ materialized }: { materialized: MaterializedOutcome }) {
  if (!materialized) return null

  if (materialized.kind === "job") {
    return (
      <div className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300">
        <span>Materialized as <EntityReference id={materialized.jobId} kind="job" /></span>
        {materialized.jobState ? <StatePill state={materialized.jobState} /> : null}
      </div>
    )
  }

  if (materialized.kind === "epic") {
    return (
      <div className="text-gray-700 dark:text-gray-300">
        Materialized as <EntityReference id={materialized.epicId} kind="epic" />
        {materialized.childJobCount > 0 ? ` (${materialized.childJobCount} child Job${materialized.childJobCount === 1 ? "" : "s"})` : ""}
      </div>
    )
  }

  return <div className="text-gray-700 dark:text-gray-300">Rejected: {materialized.reason.replace(/_/g, " ")}</div>
}

function DetailValue({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="truncate text-xs">{children}</div>
    </div>
  )
}

// Deliberately concise: this renders a tool call's *outcome* (state,
// dependencies, materialized result), not the full interactive proposal
// card (ProposalCards.tsx's ProposalCard), which already renders separately
// for the same chat_proposal item and owns edit/confirm/reject controls.
export function ProposalOutcomeCard({ proposal }: { proposal: ProposalOutcome }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{humanizeKind(proposal.kind)}</Badge>
        <StatePill state={proposal.state} />
        <EntityReference kind="proposal" slug={proposal.slug} />
      </div>
      {proposal.title ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{proposal.title}</div> : null}
      {proposal.repository || proposal.targetEpicLabel || proposal.dependencyCount > 0 || (proposal.providerSetting && proposal.providerSetting !== "default") ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {proposal.repository ? <DetailValue label="Repository"><EntityReference kind="repository" slug={proposal.repository} /></DetailValue> : null}
          {proposal.targetEpicLabel ? (
            <DetailValue label="Target epic">
              {proposal.targetEpicId ? <EntityReference id={proposal.targetEpicId} kind="epic" label={proposal.targetEpicLabel} slug={proposal.targetEpicLabel} /> : proposal.targetEpicLabel}
            </DetailValue>
          ) : null}
          {proposal.dependencyCount > 0 ? <DetailValue label="Dependencies">{proposal.dependencyCount}</DetailValue> : null}
          {proposal.providerSetting && proposal.providerSetting !== "default" ? <DetailValue label="Provider">{proposal.providerSetting}</DetailValue> : null}
        </dl>
      ) : null}
      <MaterializedOutcomeDetail materialized={proposal.materialized} />
    </CardShell>
  )
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

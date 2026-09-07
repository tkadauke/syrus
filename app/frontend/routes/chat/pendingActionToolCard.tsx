import type { ReactNode } from "react"
import { isPlainObject } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, numberValue, Row, SectionLabel, StatePill } from "./toolCardUi"

// Shared presentation for the pending-action MCP tool family (EPIC-292 /
// JOB-4222). Every tool that creates a ChatPendingAction returns one of
// three closely related JSON shapes, so one parser plus one card backs all
// ~31 of them; `tool_cards/<name>.tsx` files are thin re-exports.
//
// Lives outside `tool_cards/` on purpose: pluginToolCards.tsx globs every
// non-test .tsx file there as a card module and would warn about the
// missing default export (same reason toolCardUi.tsx sits here).
//
// These cards are strictly informational. The interactive confirm/reject
// controls live in the separate PendingActionCard (ProposalCards.tsx),
// anchored to the tool_use message; do not duplicate them here.

export type PendingActionEvidence = {
  workflowId: string | null
  branch: string | null
  remoteSha: string | null
  workflowLocalSha: string | null
  baseRef: string | null
  baseSha: string | null
  files: string[]
  diffStat: string | null
  diffUnavailableReason: string | null
}

export type PendingActionResult =
  | {
      kind: "standard" | "bulk"
      pendingActionId: string
      state: string
      message: string | null
      reason: string | null
      memberCount: number | null
      groupId: string | null
    }
  | {
      kind: "dry_run_evidence"
      action: string
      jobId: string | null
      evidence: PendingActionEvidence
      destructiveConfirmation: string | null
    }

function parseEvidence(value: unknown): PendingActionEvidence {
  const evidence = isPlainObject(value) ? value : {}
  const diffSummary = isPlainObject(evidence.diff_summary) ? evidence.diff_summary : {}
  const files = Array.isArray(diffSummary.files) ? diffSummary.files.flatMap((file) => {
    const label = displayValue(file)
    return label ? [label] : []
  }) : []

  return {
    workflowId: displayValue(evidence.workflow_id),
    branch: displayValue(evidence.branch),
    remoteSha: displayValue(evidence.remote_sha),
    workflowLocalSha: displayValue(evidence.workflow_local_sha),
    baseRef: displayValue(evidence.base_ref),
    baseSha: displayValue(evidence.base_sha),
    files,
    diffStat: displayValue(diffSummary.stat),
    // Present only when the workflow workspace was gone at evidence time.
    diffUnavailableReason: diffSummary.available === false ? displayValue(diffSummary.reason) : null
  }
}

export function parsePendingActionResult(value: unknown): PendingActionResult | null {
  if (!isPlainObject(value)) return null

  // Dry-run previews carry evidence instead of a pending action; the same
  // tools return the standard shape on their non-dry-run branch.
  if (isPlainObject(value.evidence)) {
    const action = displayValue(value.action)
    if (!action) return null

    return {
      kind: "dry_run_evidence",
      action,
      jobId: displayValue(value.job_id) || displayValue(value.evidence.job_id),
      evidence: parseEvidence(value.evidence),
      destructiveConfirmation: displayValue(value.destructive_confirmation)
    }
  }

  const pendingActionId = displayValue(value.pending_action_id) || displayValue(value.pending_confirmation_id)
  const state = displayValue(value.state)
  if (!pendingActionId || !state) return null

  const groupId = displayValue(value.pending_action_group_id)
  const memberCount = numberValue(value.member_count)

  return {
    kind: groupId || memberCount != null ? "bulk" : "standard",
    pendingActionId,
    state,
    message: displayValue(value.message),
    reason: displayValue(value.reason),
    memberCount,
    groupId
  }
}

function humanizeAction(action: string) {
  const spaced = action.replace(/_/g, " ")
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

export function pendingActionCollapsedSummary(result: PendingActionResult): string {
  if (result.kind === "dry_run_evidence") {
    return `Dry run: ${result.action}${result.jobId ? ` for JOB-${result.jobId}` : ""}`
  }

  const identifier = result.groupId ? `Pending action group #${result.groupId}` : `Pending action #${result.pendingActionId}`
  const base = result.message || `${identifier} (${result.state})`
  if (result.memberCount == null) return base

  return `${base} · ${result.memberCount} ${result.memberCount === 1 ? "action" : "actions"}`
}

function ShaRow({ label, sha }: { label: string; sha: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="truncate font-mono text-gray-700 dark:text-gray-300" title={sha}>{sha.slice(0, 12)}</dd>
    </div>
  )
}

function DetailSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">{label}</summary>
      <div className="mt-1 text-gray-700 dark:text-gray-300">{children}</div>
    </details>
  )
}

function DryRunEvidenceCard({ result }: { result: Extract<PendingActionResult, { kind: "dry_run_evidence" }> }) {
  const { evidence } = result
  const hasShas = Boolean(evidence.remoteSha || evidence.workflowLocalSha || evidence.baseSha || evidence.branch || evidence.baseRef || evidence.workflowId)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Dry run</Badge>
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{humanizeAction(result.action)}</span>
        {result.jobId ? <Badge>JOB-{result.jobId}</Badge> : null}
      </div>
      {result.destructiveConfirmation ? (
        <div className="rounded bg-amber-100 px-2 py-1 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          <span className="text-2xs font-semibold uppercase">Destructive · confirmation phrase</span>
          <div className="font-mono">{result.destructiveConfirmation}</div>
        </div>
      ) : null}
      {hasShas ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {evidence.workflowId ? <Row label="Workflow" value={`WORKFLOW-${evidence.workflowId}`} /> : null}
          {evidence.branch ? <Row label="Branch" value={evidence.branch} /> : null}
          {evidence.remoteSha ? <ShaRow label="Remote SHA" sha={evidence.remoteSha} /> : null}
          {evidence.workflowLocalSha ? <ShaRow label="Workflow local SHA" sha={evidence.workflowLocalSha} /> : null}
          {evidence.baseRef ? <Row label="Base ref" value={evidence.baseRef} /> : null}
          {evidence.baseSha ? <ShaRow label="Base SHA" sha={evidence.baseSha} /> : null}
        </dl>
      ) : null}
      {evidence.diffUnavailableReason ? (
        <div className="text-gray-500 dark:text-gray-400">Diff unavailable: {evidence.diffUnavailableReason}</div>
      ) : null}
      {evidence.files.length > 0 ? (
        <DetailSection label={`${evidence.files.length} changed ${evidence.files.length === 1 ? "file" : "files"}`}>
          <ul className="space-y-0.5 font-mono">
            {evidence.files.map((file) => (
              <li className="truncate" key={file} title={file}>{file}</li>
            ))}
          </ul>
        </DetailSection>
      ) : null}
      {evidence.diffStat ? (
        <DetailSection label="Diff stat">
          <pre className="overflow-x-auto whitespace-pre font-mono text-2xs">{evidence.diffStat}</pre>
        </DetailSection>
      ) : null}
    </CardShell>
  )
}

export function PendingActionResultCard({ result }: { result: PendingActionResult }) {
  if (result.kind === "dry_run_evidence") return <DryRunEvidenceCard result={result} />

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">
          {result.groupId ? `Group #${result.groupId}` : `#${result.pendingActionId}`}
        </span>
        {result.memberCount != null ? (
          <Badge>{result.memberCount} {result.memberCount === 1 ? "action" : "actions"}</Badge>
        ) : null}
      </div>
      {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
      {result.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{result.reason}</div>
        </div>
      ) : null}
    </CardShell>
  )
}

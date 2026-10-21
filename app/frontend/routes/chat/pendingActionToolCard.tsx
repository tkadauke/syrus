import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "../../pluginToolCards"
import { isPlainObject, normalizedToolCardParsedResult } from "../../toolCardParsing"
import { MarkdownPreview } from "./toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, numberValue, Row, SectionLabel, StatePill, type ToolCardEntityKind } from "./toolCardUi"

// Shared presentation for the pending-action MCP tool family (the pending-action tool-card work /
// Every tool that creates a ChatPendingAction returns one of
// three closely related JSON shapes, so one parser plus one card backs all
// ~34 of them; `tool_cards/<name>.tsx` files are thin re-exports.
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
  | { kind: "error"; message: string }

export type PendingActionInputField = {
  key: string
  label?: string
  format?: "plain" | "badge" | "list" | "markdown" | "entity" | "entity_list"
  entityKind?: ToolCardEntityKind
  hrefPrefix?: string
}

export type PendingActionToolCardOptions = { inputFields?: PendingActionInputField[] }

function errorMessage(value: unknown): string | null {
  if (typeof value === "string") return value.trim() || null
  if (!isPlainObject(value)) return null
  const direct = displayValue(value.error) || displayValue(value.message)
  if (direct) return direct
  const first = Array.isArray(value.content) ? value.content[0] : null
  return isPlainObject(first) ? displayValue(first.text) : null
}

function parseEvidence(value: unknown): PendingActionEvidence {
  const evidence = isPlainObject(value) ? value : {}
  const diffSummary = isPlainObject(evidence.diff_summary) ? evidence.diff_summary : {}
  const files = Array.isArray(diffSummary.files)
    ? diffSummary.files.flatMap((file) => {
        const label = displayValue(file)
        return label ? [label] : []
      })
    : []

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

export function parsePendingActionResult(context: ToolCardContext, includeError = false): PendingActionResult | null {
  const value = normalizedToolCardParsedResult(context.parsedResult)
  if (!isPlainObject(value)) {
    return includeError && context.resultError ? { kind: "error", message: errorMessage(value) || context.resultBody || "The tool returned an error." } : null
  }

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
  if (!pendingActionId || !state) {
    return includeError && context.resultError ? { kind: "error", message: errorMessage(value) || context.resultBody || "The tool returned an error." } : null
  }

  const groupId = displayValue(value.pending_action_group_id)
  const memberCount = numberValue(value.member_count)

  // The tool result's own state is a snapshot frozen at call time -- it
  // still says "pending" forever once the operator later confirms/rejects
  // it. context.livePendingAction is re-read from the owning message on
  // every payload fetch, so prefer it once it exists and still refers to
  // this same pending action (a resumed/retried tool call can carry an
  // older payload's id while the message itself moved on).
  const live = context.livePendingAction
  const liveMatch = live && displayValue(live.id) === pendingActionId ? live : null

  return {
    kind: groupId || memberCount != null ? "bulk" : "standard",
    pendingActionId,
    state: liveMatch?.state ?? state,
    message: displayValue(value.message),
    reason: liveMatch?.reason || displayValue(value.reason),
    memberCount,
    groupId
  }
}

function humanizeAction(action: string) {
  const spaced = action.replace(/_/g, " ")
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

export function pendingActionCollapsedSummary(result: PendingActionResult): string {
  if (result.kind === "error") return result.message
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
      <dt className="text-2xs font-semibold uppercase text-text-muted">{label}</dt>
      <dd className="truncate font-mono text-text-primary" title={sha}>
        {sha.slice(0, 12)}
      </dd>
    </div>
  )
}

function DetailSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <summary className="min-h-11 cursor-pointer py-3 text-2xs font-semibold uppercase text-text-muted hover:text-text-primary sm:min-h-0 sm:py-1">
        {label}
      </summary>
      <div className="mt-1 text-text-primary">{children}</div>
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
        <span className="font-mono font-semibold text-text-primary">{humanizeAction(result.action)}</span>
        {result.jobId ? <Badge>JOB-{result.jobId}</Badge> : null}
      </div>
      {result.destructiveConfirmation ? (
        <div className="rounded bg-warning-surface px-2 py-1 text-warning-text">
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
      {evidence.diffUnavailableReason ? <div className="text-text-muted">Diff unavailable: {evidence.diffUnavailableReason}</div> : null}
      {evidence.files.length > 0 ? (
        <DetailSection label={`${evidence.files.length} changed ${evidence.files.length === 1 ? "file" : "files"}`}>
          <ul className="space-y-0.5 font-mono">
            {evidence.files.map((file) => (
              <li className="truncate" key={file} title={file}>
                {file}
              </li>
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

function inputLabel(field: PendingActionInputField) {
  return field.label || field.key.replace(/_/g, " ").replace(/^./, (character) => character.toUpperCase())
}

function linkedPendingProse(value: string) {
  return value
    .replace(/\bworkflow #(\d+)\b/gi, (_match, id: string) => `[workflow #${id}](/admin/workflows/${id})`)
    .replace(/\bprocess #(\d+)\b/gi, (_match, id: string) => `[process #${id}](/admin/processes/${id})`)
    .replace(/\buser #(\d+)\b/gi, (_match, id: string) => `[user #${id}](/admin/users/${id})`)
    .replace(/(?<![\w@])([\w.+-]+@[\w.-]+\.[A-Za-z]{2,})(?![\w@])/g, "[$1](mailto:$1)")
}

function InputValue({ field, value }: { field: PendingActionInputField; value: unknown }) {
  const format = field.format || "plain"
  if (format === "markdown")
    return (
      <MarkdownPreview linkifySlugs linkifyUrls maxChars={600} maxLines={3} modalLabel={`Full ${inputLabel(field).toLowerCase()}`} text={displayValue(value)} />
    )
  if (format === "entity" || format === "entity_list") {
    const values = format === "entity_list" && Array.isArray(value) ? value : [value]
    return (
      <div className="flex min-w-0 flex-wrap gap-1">
        {values.map((item, index) => {
          const id = displayValue(item)
          if (!id) return null
          return (
            <EntityReference
              href={field.hrefPrefix ? `${field.hrefPrefix}/${id}` : null}
              id={id}
              key={`${id}-${index}`}
              kind={field.entityKind || "artifact"}
              touchTarget
              wrap="break"
            />
          )
        })}
      </div>
    )
  }
  if (format === "list" && Array.isArray(value)) {
    return (
      <div className="flex min-w-0 flex-wrap gap-1">
        {value.map((item, index) => {
          const displayed = displayValue(item)
          return displayed ? <Badge key={`${displayed}-${index}`}>{displayed}</Badge> : null
        })}
      </div>
    )
  }
  const displayed = displayValue(value)
  if (!displayed) return null
  return format === "badge" ? <Badge>{displayed}</Badge> : <span className="break-all text-text-primary [overflow-wrap:anywhere]">{displayed}</span>
}

function InputDetails({ fields, input }: { fields: PendingActionInputField[]; input?: Record<string, unknown> }) {
  if (!input) return null
  const populated = fields.filter((field) => {
    const value = input[field.key]
    return Array.isArray(value) ? value.length > 0 : value != null && displayValue(value) !== ""
  })
  if (populated.length === 0) return null
  return (
    <div>
      <SectionLabel>Targets and parameters</SectionLabel>
      <dl className="mt-1 grid min-w-0 gap-2 sm:grid-cols-2">
        {populated.map((field) => (
          <div className={field.format === "markdown" ? "min-w-0 sm:col-span-2" : "min-w-0"} key={field.key}>
            <dt className="text-2xs font-semibold uppercase text-text-muted">{inputLabel(field)}</dt>
            <dd className="mt-0.5 min-w-0">
              <InputValue field={field} value={input[field.key]} />
            </dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

export function PendingActionResultCard({
  result,
  input,
  inputFields = []
}: {
  result: PendingActionResult
  input?: Record<string, unknown>
  inputFields?: PendingActionInputField[]
}) {
  if (result.kind === "error")
    return (
      <CardShell>
        <StatePill state="failed" />
        <InputDetails fields={inputFields} input={input} />
        <MarkdownPreview linkifySlugs linkifyUrls maxChars={600} maxLines={3} modalLabel="Full tool error" text={result.message} title="Tool error" />
      </CardShell>
    )
  if (result.kind === "dry_run_evidence") return <DryRunEvidenceCard result={result} />

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <span className="font-mono font-semibold text-text-primary">
          {result.groupId ? `Pending action group #${result.groupId}` : `Pending action #${result.pendingActionId}`}
        </span>
        {result.memberCount != null ? (
          <Badge>
            {result.memberCount} {result.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>
      <InputDetails fields={inputFields} input={input} />
      {result.message ? (
        <MarkdownPreview
          linkifySlugs
          linkifyUrls
          maxChars={600}
          maxLines={3}
          modalLabel="Full pending action message"
          text={linkedPendingProse(result.message)}
        />
      ) : null}
      {result.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <MarkdownPreview
            linkifySlugs
            linkifyUrls
            maxChars={600}
            maxLines={3}
            modalLabel="Full pending action reason"
            text={linkedPendingProse(result.reason)}
          />
        </div>
      ) : null}
    </CardShell>
  )
}

export function pendingActionToolCard(toolName: string, options: PendingActionToolCardOptions = {}): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary(context) {
      const result = parsePendingActionResult(context, true)
      return result ? pendingActionCollapsedSummary(result) : null
    },
    renderExpanded(context) {
      const result = parsePendingActionResult(context, true)
      return result ? <PendingActionResultCard input={context.input} inputFields={options.inputFields} result={result} /> : null
    }
  }
}

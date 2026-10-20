import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "../../pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
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

export type PendingActionInputField = {
  key: string
  label?: string
  format?: "text" | "badge" | "list" | "markdown" | "entity" | "entity_list"
  entityKind?: ToolCardEntityKind
}

export type PendingActionToolCardOptions = {
  inputFields?: PendingActionInputField[]
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

export function parsePendingActionResult(context: ToolCardContext): PendingActionResult | null {
  const value = context.parsedResult
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

  // The tool result's own state is a snapshot frozen at call time -- it
  // still says "pending" forever once the operator later confirms/rejects
  // it. context.livePendingAction is re-read from the owning message on
  // every payload fetch, so prefer it once it exists and still refers to
  // this same pending action (a resumed/retried tool call can carry an
  // older payload's id while the message itself moved on).
  const live = context.livePendingAction
  const liveMatch = live && displayValue(live.id) === pendingActionId ? live : null
  const liveGroup = context.livePendingActionGroup
  const liveGroupMatch = groupId && liveGroup && displayValue(liveGroup.id) === groupId ? liveGroup : null

  return {
    kind: groupId || memberCount != null ? "bulk" : "standard",
    pendingActionId,
    state: liveGroupMatch?.state ?? liveMatch?.state ?? state,
    message: displayValue(value.message),
    reason: liveGroupMatch?.reason || liveMatch?.reason || displayValue(value.reason),
    memberCount,
    groupId
  }
}

function humanizeAction(action: string) {
  const spaced = action.replace(/_/g, " ")
  return spaced.charAt(0).toUpperCase() + spaced.slice(1)
}

function linkedPendingProse(text: string) {
  return text
    .replace(/\bworkflow #(\d+)\b/gi, (_match, id: string) => `[workflow #${id}](/admin/workflows/${id})`)
    .replace(/\bprocess #(\d+)\b/gi, (_match, id: string) => `[process #${id}](/admin/processes/${id})`)
    .replace(/\buser #(\d+)\b/gi, (_match, id: string) => `[user #${id}](/admin/users/${id})`)
    .replace(/(?<![\w/:\[])((?:[A-Z0-9._%+-]+)@[A-Z0-9.-]+\.[A-Z]{2,})\b/gi, "[$1](mailto:$1)")
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
      <summary className="flex min-h-11 cursor-pointer items-center text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">{label}</summary>
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
        <div className="rounded-[var(--radius-panel)] bg-warning-surface px-2 py-1 text-warning-text">
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

export function PendingActionResultCard({ result }: { result: PendingActionResult }) {
  if (result.kind === "dry_run_evidence") return <DryRunEvidenceCard result={result} />

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <span className="font-mono font-semibold text-text-primary">{result.groupId ? `Group #${result.groupId}` : `#${result.pendingActionId}`}</span>
        {result.memberCount != null ? (
          <Badge>
            {result.memberCount} {result.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>
      {result.message ? <MarkdownPreview maxLines={3} text={linkedPendingProse(result.message)} title="Message" /> : null}
      {result.reason ? <MarkdownPreview text={linkedPendingProse(result.reason)} title="Reason" /> : null}
    </CardShell>
  )
}

function inputLabel(field: PendingActionInputField) {
  if (field.label) return field.label
  const words = field.key.replace(/_ids?$/, "").replace(/_/g, " ")
  return words.charAt(0).toUpperCase() + words.slice(1)
}

function entityValue(value: unknown, field: PendingActionInputField) {
  const id = displayValue(value)
  if (!id || !field.entityKind) return null
  const href = field.entityKind === "workflow" ? `/admin/workflows/${id}` : undefined
  return (
    <EntityReference
      className="[&_a]:inline-flex [&_a]:min-h-11 [&_a]:items-center [&_button]:h-11 [&_button]:w-11"
      href={href}
      id={id}
      kind={field.entityKind}
    />
  )
}

function InputField({ field, value }: { field: PendingActionInputField; value: unknown }) {
  const label = inputLabel(field)
  if (field.format === "markdown") {
    const text = displayValue(value)
    return text ? <MarkdownPreview text={text} title={label} /> : null
  }
  if (field.format === "entity") {
    const rendered = entityValue(value, field)
    return rendered ? (
      <div className="min-w-0">
        <SectionLabel>{label}</SectionLabel>
        <div className="mt-0.5">{rendered}</div>
      </div>
    ) : null
  }
  if (field.format === "entity_list") {
    if (!Array.isArray(value)) return null
    const rendered = value.map((item) => ({ id: displayValue(item), node: entityValue(item, field) })).filter((item) => item.id && item.node)
    return rendered.length ? (
      <div className="min-w-0">
        <SectionLabel>{label}</SectionLabel>
        <div className="mt-1 flex flex-wrap gap-1">
          {rendered.map((item) => (
            <Badge key={item.id}>{item.node}</Badge>
          ))}
        </div>
      </div>
    ) : null
  }
  if (field.format === "list") {
    if (!Array.isArray(value)) return null
    const values = value.flatMap((item) => displayValue(item) ?? [])
    return values.length ? (
      <div className="min-w-0">
        <SectionLabel>{label}</SectionLabel>
        <div className="mt-1 flex flex-wrap gap-1">
          {values.map((item) => (
            <Badge key={item}>{item}</Badge>
          ))}
        </div>
      </div>
    ) : null
  }
  const text = displayValue(value)
  if (!text) return null
  return field.format === "badge" ? (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1">
        <Badge>{text}</Badge>
      </div>
    </div>
  ) : (
    <Row label={label} value={text} />
  )
}

function PendingActionInputs({ input, fields }: { input: Record<string, unknown>; fields: PendingActionInputField[] }) {
  const present = fields.filter((field) => input[field.key] != null)
  if (present.length === 0) return null
  return (
    <div className="grid min-w-0 gap-2 sm:grid-cols-2">
      {present.map((field) => (
        <InputField field={field} key={field.key} value={input[field.key]} />
      ))}
    </div>
  )
}

function pendingActionHref(context: ToolCardContext) {
  const path = context.livePendingActionGroup?.app_confirm_path || context.livePendingAction?.app_confirm_path
  const chatId = path?.match(/\/chats\/(\d+)\/pending_action(?:_group)?s\//)?.[1]
  return chatId ? `/chats/${chatId}` : null
}

function PendingActionConfiguredCard({
  context,
  result,
  options
}: {
  context: ToolCardContext
  result: PendingActionResult
  options: PendingActionToolCardOptions
}) {
  if (result.kind === "dry_run_evidence") return <PendingActionResultCard result={result} />
  const href = pendingActionHref(context)
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {href ? (
          <a className="inline-flex min-h-11 items-center font-mono font-semibold text-brand hover:underline" href={href}>
            {result.groupId ? `Group #${result.groupId}` : `#${result.pendingActionId}`}
          </a>
        ) : (
          <span className="font-mono font-semibold text-text-primary">{result.groupId ? `Group #${result.groupId}` : `#${result.pendingActionId}`}</span>
        )}
        {result.memberCount != null ? (
          <Badge>
            {result.memberCount} {result.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>
      {context.input && options.inputFields?.length ? <PendingActionInputs fields={options.inputFields} input={context.input} /> : null}
      {result.message ? <MarkdownPreview maxLines={3} text={linkedPendingProse(result.message)} title="Message" /> : null}
      {result.reason ? <MarkdownPreview text={linkedPendingProse(result.reason)} title="Reason" /> : null}
    </CardShell>
  )
}

// Additive factory: existing wrappers may continue using the exported parser
// and result component, while target-aware wrappers opt into input rendering.
export function pendingActionToolCard(toolName: string, options: PendingActionToolCardOptions = {}): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary(context) {
      const result = parsePendingActionResult(context)
      return result ? pendingActionCollapsedSummary(result) : null
    },
    renderExpanded(context) {
      const result = parsePendingActionResult(context)
      return result ? <PendingActionConfiguredCard context={context} options={options} result={result} /> : null
    }
  }
}

import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardRenderer } from "../../pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
import { normalizedToolCardParsedResult } from "./toolRendering"
import { MarkdownPreview } from "./toolCardMarkdown"
import {
  Badge,
  CardShell,
  displayValue,
  EntityReference,
  entityReferenceLabel,
  numberValue,
  Row,
  SectionLabel,
  StatePill,
  type ToolCardEntityKind
} from "./toolCardUi"

type TargetContext = {
  jobId: string | null
  workflowId: string | null
  runId: string | null
  prNumber: string | null
  prUrl: string | null
  branch: string | null
  branchUrl: string | null
  blockerKey: string | null
  instructions: string | null
  inputReason: string | null
}

export type PendingActionEvidence = TargetContext & {
  remoteSha: string | null
  workflowLocalSha: string | null
  baseRef: string | null
  baseSha: string | null
  files: string[]
  diffStat: string | null
  diffUnavailableReason: string | null
}

type LiveDetails = {
  executionStatus: string | null
  executionStep: string | null
  executionError: string | null
  resourceTitle: string | null
  resourceUrl: string | null
  detail: string | null
}

export type PendingActionResult =
  | ({
      kind: "standard" | "bulk"
      pendingActionId: string
      state: string
      message: string | null
      reason: string | null
      memberCount: number | null
      groupId: string | null
    } & TargetContext &
      LiveDetails)
  | {
      kind: "dry_run_evidence"
      action: string
      evidence: PendingActionEvidence | null
      plan: Record<string, unknown> | null
      destructiveConfirmation: string | null
      context: TargetContext
    }
  | ({ kind: "error"; code: string | null; message: string; validBases: string[] } & TargetContext)

export type PendingActionInputField = {
  key: string
  label?: string
  format?: "plain" | "badge" | "list" | "markdown" | "entity" | "entity_list"
  entityKind?: ToolCardEntityKind
  hrefPrefix?: string
}

export type PendingActionToolCardOptions = { inputFields?: PendingActionInputField[] }

function parsedErrorMessage(value: unknown): string | null {
  if (typeof value === "string") return value.trim() || null
  if (!isPlainObject(value)) return null
  const direct = displayValue(value.error) || displayValue(value.message)
  if (direct) return direct
  const first = Array.isArray(value.content) ? value.content[0] : null
  return isPlainObject(first) ? displayValue(first.text) : null
}

function githubUrls(repository: string | null, prNumber: string | null, branch: string | null) {
  return {
    prUrl: repository && prNumber ? `https://github.com/${repository}/pull/${prNumber}` : null,
    branchUrl: repository && branch ? `https://github.com/${repository}/tree/${encodeURIComponent(branch)}` : null
  }
}

function parseContext(value: Record<string, unknown>, fallback: Record<string, unknown> = {}): TargetContext {
  const currentPr = isPlainObject(value.current_pr) ? value.current_pr : {}
  const repository = displayValue(currentPr.repository) || displayValue(value.repository) || displayValue(fallback.repository)
  const prNumber = displayValue(currentPr.number) || displayValue(value.pr_number) || displayValue(fallback.pr_number)
  const branch = displayValue(value.branch) || displayValue(value.branch_name) || displayValue(fallback.branch) || displayValue(fallback.branch_name)
  const urls = githubUrls(repository, prNumber, branch)
  return {
    jobId: displayValue(value.job_id) || displayValue(fallback.job_id),
    workflowId: displayValue(value.workflow_id) || displayValue(fallback.workflow_id),
    runId: displayValue(value.run_id) || displayValue(fallback.run_id),
    prNumber,
    prUrl: displayValue(currentPr.url) || displayValue(value.pr_url) || displayValue(fallback.pr_url) || urls.prUrl,
    branch,
    branchUrl: displayValue(value.branch_url) || displayValue(fallback.branch_url) || urls.branchUrl,
    blockerKey: displayValue(value.blocker_key) || displayValue(fallback.blocker_key),
    instructions: displayValue(value.instructions) || displayValue(fallback.instructions),
    inputReason: displayValue(value.reason) || displayValue(fallback.reason)
  }
}

function parseEvidence(value: unknown, fallback: Record<string, unknown>): PendingActionEvidence {
  const evidence = isPlainObject(value) ? value : {}
  const diff = isPlainObject(evidence.diff_summary) ? evidence.diff_summary : {}
  const files = Array.isArray(diff.files)
    ? diff.files.flatMap((file) => {
        const label = displayValue(file)
        return label ? [label] : []
      })
    : []
  return {
    ...parseContext(evidence, fallback),
    remoteSha: displayValue(evidence.remote_sha),
    workflowLocalSha: displayValue(evidence.workflow_local_sha),
    baseRef: displayValue(evidence.base_ref),
    baseSha: displayValue(evidence.base_sha),
    files,
    diffStat: displayValue(diff.stat),
    diffUnavailableReason: diff.available === false ? displayValue(diff.reason) : null
  }
}

function stringList(value: unknown) {
  return Array.isArray(value)
    ? value.flatMap((entry) => {
        const label = displayValue(entry)
        return label ? [label] : []
      })
    : []
}

export function parsePendingActionResult(context: ToolCardContext): PendingActionResult | null {
  const value = normalizedToolCardParsedResult(context.parsedResult)
  if (context.resultError)
    return {
      kind: "error",
      code: null,
      message: parsedErrorMessage(value) || context.resultBody || "The tool returned an error.",
      validBases: [],
      ...parseContext(context.input ?? {})
    }
  if (!isPlainObject(value)) return null
  const input = context.input ?? {}
  const target = parseContext(input)
  const error = displayValue(value.error)
  const errorMessage = displayValue(value.message)
  if (error && errorMessage) return { kind: "error", code: error, message: errorMessage, validBases: stringList(value.valid_bases), ...target }

  const pendingActionId = displayValue(value.pending_action_id) || displayValue(value.pending_confirmation_id)
  const state = displayValue(value.state)
  if (pendingActionId && state) {
    const groupId = displayValue(value.pending_action_group_id)
    const memberCount = numberValue(value.member_count)
    const live = context.livePendingAction
    const liveMatch = live && displayValue(live.id) === pendingActionId ? live : null
    return {
      kind: groupId || memberCount != null ? "bulk" : "standard",
      pendingActionId,
      state: liveMatch?.state ?? state,
      message: displayValue(value.message),
      reason: liveMatch?.reason || displayValue(value.reason) || target.inputReason,
      memberCount,
      groupId,
      ...parseContext(value, input),
      executionStatus: displayValue(liveMatch?.execution_status),
      executionStep: displayValue(liveMatch?.execution_step),
      executionError: displayValue(liveMatch?.execution_error),
      resourceTitle: displayValue(liveMatch?.resource_title),
      resourceUrl: displayValue(liveMatch?.resource_url),
      detail: displayValue(liveMatch?.detail)
    }
  }

  // Evidence payloads may omit target identity that remains available at the
  // result level (notably adopt_current_pr_head's top-level job_id). Preserve
  // both that result context and the original input when rendering evidence.
  const evidenceFallback = { ...input, ...value }
  const evidence = isPlainObject(value.evidence) ? parseEvidence(value.evidence, evidenceFallback) : null
  const plan = isPlainObject(value.plan) ? value.plan : input.dry_run === true || evidence ? value : null
  if (!plan && !evidence) return null
  return {
    kind: "dry_run_evidence",
    action: displayValue(value.action) || displayValue(value.operation) || context.toolName,
    evidence,
    plan,
    destructiveConfirmation: displayValue(value.destructive_confirmation),
    context: parseContext(value, input)
  }
}

function humanizeAction(action: string) {
  const text = action.replace(/_/g, " ")
  return text.charAt(0).toUpperCase() + text.slice(1)
}

const COLLAPSED_SUMMARY_MAX_CHARS = 160

function compactCollapsedSummary(text: string) {
  const plainText = text
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[`*_~]/g, "")
    .replace(/\s+/g, " ")
    .trim()
  if (plainText.length <= COLLAPSED_SUMMARY_MAX_CHARS) return plainText
  return `${plainText.slice(0, COLLAPSED_SUMMARY_MAX_CHARS - 1).trimEnd()}…`
}

export function pendingActionCollapsedSummary(result: PendingActionResult): string {
  if (result.kind === "error") return compactCollapsedSummary(result.code ? `${result.code}: ${result.message}` : result.message)
  if (result.kind === "dry_run_evidence") {
    const jobId = result.context.jobId || result.evidence?.jobId
    return `Dry run: ${result.action}${jobId ? ` for ${entityReferenceLabel({ kind: "job", id: jobId })}` : ""}`
  }
  const identifier = result.groupId ? `Pending action group #${result.groupId}` : `Pending action #${result.pendingActionId}`
  const base = result.message || `${identifier} (${result.state})`
  const summary = result.memberCount == null ? base : `${base} · ${result.memberCount} ${result.memberCount === 1 ? "action" : "actions"}`
  return compactCollapsedSummary(summary)
}

function ShaRow({ label, sha }: { label: string; sha: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-semibold uppercase text-text-muted">{label}</dt>
      <dd className="break-all font-mono text-text-primary" title={sha}>
        {sha}
      </dd>
    </div>
  )
}

function DetailSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <summary className="flex min-h-11 cursor-pointer items-center text-2xs font-semibold uppercase text-text-muted hover:text-text-primary sm:min-h-7">
        {label}
      </summary>
      <div className="mt-1 text-text-primary">{children}</div>
    </details>
  )
}

function ContextRows({ value }: { value: TargetContext }) {
  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
      {value.jobId ? <Row label="Job" value={<EntityReference id={value.jobId} kind="job" />} /> : null}
      {value.workflowId ? <Row label="Workflow" value={<EntityReference id={value.workflowId} jobId={value.jobId} kind="workflow" />} /> : null}
      {value.runId ? <Row label="Run" value={<EntityReference id={value.runId} jobId={value.jobId} kind="run" workflowId={value.workflowId} />} /> : null}
      {value.prNumber ? <Row label="Pull request" value={<EntityReference id={value.prNumber} kind="pull_request" prUrl={value.prUrl} />} /> : null}
      {value.branch ? (
        <Row
          label="Branch"
          value={
            value.branchUrl ? (
              <a className="break-all font-mono font-medium text-brand hover:underline" href={value.branchUrl} rel="noreferrer" target="_blank">
                {value.branch}
              </a>
            ) : (
              <span className="break-all font-mono">{value.branch}</span>
            )
          }
        />
      ) : null}
      {value.blockerKey ? <Row label="Blocker key" value={<span className="break-all font-mono">{value.blockerKey}</span>} /> : null}
    </dl>
  )
}

function DryRunCard({ details, result }: { details?: ReactNode; result: Extract<PendingActionResult, { kind: "dry_run_evidence" }> }) {
  const evidence = result.evidence
  const target = evidence ?? result.context
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>Dry run</Badge>
        <span className="break-words font-mono font-semibold text-text-primary">{humanizeAction(result.action)}</span>
        {target.jobId ? (
          <Badge>
            <EntityReference id={target.jobId} kind="job" />
          </Badge>
        ) : null}
      </div>
      {result.destructiveConfirmation ? (
        <div className="rounded-[var(--radius-control)] bg-warning/10 px-2 py-1 text-warning-text">
          <span className="text-2xs font-semibold uppercase">Destructive · confirmation phrase</span>
          <div className="break-all font-mono">{result.destructiveConfirmation}</div>
        </div>
      ) : null}
      <ContextRows value={target} />
      {details}
      {evidence?.remoteSha ? <ShaRow label="Remote SHA" sha={evidence.remoteSha} /> : null}
      {evidence?.workflowLocalSha ? <ShaRow label="Workflow local SHA" sha={evidence.workflowLocalSha} /> : null}
      {evidence?.baseRef ? <Row label="Base ref" value={<span className="break-all font-mono">{evidence.baseRef}</span>} /> : null}
      {evidence?.baseSha ? <ShaRow label="Base SHA" sha={evidence.baseSha} /> : null}
      {evidence?.diffUnavailableReason ? <div className="text-text-muted">Diff unavailable: {evidence.diffUnavailableReason}</div> : null}
      {evidence?.files.length ? (
        <DetailSection label={`${evidence.files.length} changed ${evidence.files.length === 1 ? "file" : "files"}`}>
          <ul className="space-y-0.5 font-mono">
            {evidence.files.map((file) => (
              <li className="break-all" key={file}>
                {file}
              </li>
            ))}
          </ul>
        </DetailSection>
      ) : null}
      {evidence?.diffStat ? (
        <DetailSection label="Diff stat">
          <pre className="whitespace-pre-wrap break-words font-mono text-2xs [overflow-wrap:anywhere]">{evidence.diffStat}</pre>
        </DetailSection>
      ) : null}
      {result.plan && !evidence ? (
        <DetailSection label="Plan / eligibility">
          <pre className="whitespace-pre-wrap break-words font-mono text-2xs [overflow-wrap:anywhere]">{JSON.stringify(result.plan, null, 2)}</pre>
        </DetailSection>
      ) : null}
      {result.context.instructions ? <MarkdownPreview maxLines={4} modalLabel="Instructions" text={result.context.instructions} title="Instructions" /> : null}
      {result.context.inputReason ? <MarkdownPreview maxLines={4} modalLabel="Reason" text={result.context.inputReason} title="Reason" /> : null}
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
          return id ? (
            <EntityReference
              href={field.hrefPrefix ? `${field.hrefPrefix}/${id}` : null}
              id={id}
              key={`${id}-${index}`}
              kind={field.entityKind || "artifact"}
              touchTarget
              wrap="break"
            />
          ) : null
        })}
      </div>
    )
  }
  if (format === "list" && Array.isArray(value))
    return (
      <div className="flex min-w-0 flex-wrap gap-1">
        {value.map((item, index) => {
          const displayed = displayValue(item)
          return displayed ? <Badge key={`${displayed}-${index}`}>{displayed}</Badge> : null
        })}
      </div>
    )
  const displayed = displayValue(value)
  if (!displayed) return null
  return format === "badge" ? <Badge>{displayed}</Badge> : <span className="break-all text-text-primary [overflow-wrap:anywhere]">{displayed}</span>
}

function InputDetails({ fields, input }: { fields: PendingActionInputField[]; input?: Record<string, unknown> }) {
  if (!input) return null
  const populated = fields.filter((field) =>
    Array.isArray(input[field.key]) ? (input[field.key] as unknown[]).length > 0 : input[field.key] != null && displayValue(input[field.key]) !== ""
  )
  if (!populated.length) return null
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
  details,
  input,
  inputFields = [],
  result
}: {
  details?: ReactNode
  input?: Record<string, unknown>
  inputFields?: PendingActionInputField[]
  result: PendingActionResult
}) {
  if (result.kind === "dry_run_evidence") return <DryRunCard details={details} result={result} />
  if (result.kind === "error")
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="failed" />
          {result.code ? <span className="break-all font-mono font-semibold text-danger-text">{result.code}</span> : null}
        </div>
        <InputDetails fields={inputFields} input={input} />
        <MarkdownPreview linkifySlugs linkifyUrls maxChars={600} maxLines={4} modalLabel="Error details" text={result.message} />
        <ContextRows value={result} />
        {details}
        {result.validBases.length ? <Row label="Valid bases" value={<span className="break-words font-mono">{result.validBases.join(", ")}</span>} /> : null}
      </CardShell>
    )
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        {result.groupId ? (
          <EntityReference href={result.resourceUrl} id={result.groupId} kind="artifact" label={`Group #${result.groupId}`} />
        ) : (
          <EntityReference href={result.resourceUrl} id={result.pendingActionId} kind="artifact" label={`#${result.pendingActionId}`} />
        )}
        {result.memberCount != null ? (
          <Badge>
            {result.memberCount} {result.memberCount === 1 ? "action" : "actions"}
          </Badge>
        ) : null}
      </div>
      <InputDetails fields={inputFields} input={input} />
      <ContextRows value={result} />
      {details}
      {result.resourceTitle && result.resourceUrl ? (
        <Row label="Resource" value={<EntityReference href={result.resourceUrl} id={result.resourceTitle} kind="artifact" label={result.resourceTitle} />} />
      ) : null}
      {result.executionStatus ? <Row label="Execution status" value={<StatePill state={result.executionStatus} />} /> : null}
      {result.executionStep ? <Row label="Execution step" value={<span className="break-all font-mono">{result.executionStep}</span>} /> : null}
      {result.message ? (
        <MarkdownPreview linkifySlugs linkifyUrls maxChars={600} maxLines={4} modalLabel="Pending action message" text={linkedPendingProse(result.message)} />
      ) : null}
      {result.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <MarkdownPreview linkifySlugs linkifyUrls maxChars={600} maxLines={4} modalLabel="Pending action reason" text={linkedPendingProse(result.reason)} />
        </div>
      ) : null}
      {result.instructions ? <MarkdownPreview maxLines={4} modalLabel="Instructions" text={result.instructions} title="Instructions" /> : null}
      {result.detail ? <MarkdownPreview maxLines={4} modalLabel="Pending action detail" text={result.detail} title="Detail" /> : null}
      {result.executionError ? (
        <MarkdownPreview className="text-danger-text" maxLines={4} modalLabel="Execution error" text={result.executionError} title="Execution error" />
      ) : null}
    </CardShell>
  )
}

export function pendingActionToolCard(toolName: string, options: PendingActionToolCardOptions = {}): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary(context) {
      const result = parsePendingActionResult(context)
      return result ? pendingActionCollapsedSummary(result) : null
    },
    renderExpanded(context) {
      const result = parsePendingActionResult(context)
      return result ? <PendingActionResultCard input={context.input} inputFields={options.inputFields} result={result} /> : null
    }
  }
}

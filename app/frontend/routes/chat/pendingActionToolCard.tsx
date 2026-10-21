import type { ReactNode } from "react"
import type { ToolCardContext } from "../../pluginToolCards"
import { isPlainObject } from "../../toolCardParsing"
import { MarkdownPreview } from "./toolCardMarkdown"
import { Badge, CardShell, displayValue, EntityReference, entityReferenceLabel, numberValue, Row, SectionLabel, StatePill } from "./toolCardUi"

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
  | ({ kind: "error"; code: string; message: string; validBases: string[] } & TargetContext)

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
  const branch = displayValue(value.branch) || displayValue(fallback.branch)
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

function parseEvidence(value: unknown, input: Record<string, unknown>): PendingActionEvidence {
  const evidence = isPlainObject(value) ? value : {}
  const diff = isPlainObject(evidence.diff_summary) ? evidence.diff_summary : {}
  const files = Array.isArray(diff.files)
    ? diff.files.flatMap((file) => {
        const label = displayValue(file)
        return label ? [label] : []
      })
    : []
  return {
    ...parseContext(evidence, input),
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
  const value = context.parsedResult
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

  const evidence = isPlainObject(value.evidence) ? parseEvidence(value.evidence, input) : null
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

export function pendingActionCollapsedSummary(result: PendingActionResult): string {
  if (result.kind === "error") return `${result.code}: ${result.message}`
  if (result.kind === "dry_run_evidence") {
    const jobId = result.context.jobId || result.evidence?.jobId
    return `Dry run: ${result.action}${jobId ? ` for ${entityReferenceLabel({ kind: "job", id: jobId })}` : ""}`
  }
  const identifier = result.groupId ? `Pending action group #${result.groupId}` : `Pending action #${result.pendingActionId}`
  const base = result.message || `${identifier} (${result.state})`
  return result.memberCount == null ? base : `${base} · ${result.memberCount} ${result.memberCount === 1 ? "action" : "actions"}`
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

function DryRunCard({ result }: { result: Extract<PendingActionResult, { kind: "dry_run_evidence" }> }) {
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

export function PendingActionResultCard({ result }: { result: PendingActionResult }) {
  if (result.kind === "dry_run_evidence") return <DryRunCard result={result} />
  if (result.kind === "error")
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="failed" />
          <span className="break-all font-mono font-semibold text-danger-text">{result.code}</span>
        </div>
        <MarkdownPreview maxLines={4} modalLabel="Error details" text={result.message} />
        <ContextRows value={result} />
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
      <ContextRows value={result} />
      {result.resourceTitle && result.resourceUrl ? (
        <Row label="Resource" value={<EntityReference href={result.resourceUrl} id={result.resourceTitle} kind="artifact" label={result.resourceTitle} />} />
      ) : null}
      {result.executionStatus ? <Row label="Execution status" value={<StatePill state={result.executionStatus} />} /> : null}
      {result.executionStep ? <Row label="Execution step" value={<span className="break-all font-mono">{result.executionStep}</span>} /> : null}
      {result.message ? <MarkdownPreview maxLines={4} modalLabel="Pending action message" text={result.message} /> : null}
      {result.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <MarkdownPreview maxLines={4} modalLabel="Pending action reason" text={result.reason} />
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

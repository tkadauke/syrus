import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, InternalLink, Row, SectionLabel, StatePill } from "../toolCardUi"

type Ref = { id: string; state: string | null; kind: string | null; workflowId: string | null }
type Diagnostic = {
  key: string
  kind: string
  severity: string | null
  attention: string | null
  detail: string | null
  workflowId: string | null
  runId: string | null
  repair: string | null
}
type Dependency = { key: string; jobId: string | null; epicId: string | null; slug: string | null; state: string | null; unresolved: string | null }
type Action = {
  action: string
  reason: string | null
  runId: string | null
  workflowId: string | null
  prNumber: string | null
  workUnitId: string | null
  nextCheckAt: string | null
}
type Intent = { id: string; kind: string | null; state: string | null; waitReason: string | null; waitUntil: string | null }
type WorkUnit = Ref & { blockedReason: string | null }

type Card = {
  jobId: string
  slug: string | null
  title: string | null
  state: string
  stuck: boolean
  branch: string | null
  prNumber: string | null
  prUrl: string | null
  closureReason: string | null
  landingFailure: string | null
  action: Action | null
  summary: string | null
  issues: Diagnostic[]
  stuckItems: Diagnostic[]
  intent: Intent | null
  workflows: Ref[]
  runs: Ref[]
  dependencies: Dependency[]
  workUnits: WorkUnit[]
  landing: string | null
}

function diagnostics(value: unknown): Diagnostic[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    if (!isPlainObject(item)) return []
    const kind = displayValue(item.kind)
    if (!kind) return []
    const plan = isPlainObject(item.repair_plan) ? item.repair_plan : null
    const workflowId = displayValue(item.workflow_id)
    const runId = displayValue(item.run_id)
    return [
      {
        key: `${kind}-${workflowId ?? ""}-${runId ?? ""}-${index}`,
        kind,
        severity: displayValue(item.severity),
        attention: displayValue(item.attention_state),
        detail: displayValue(item.detail),
        workflowId,
        runId,
        repair: displayValue(plan?.action)
      }
    ]
  })
}

function refs(value: unknown): Ref[] {
  const values = Array.isArray(value) ? value : value == null ? [] : [value]
  return values.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    return id
      ? [
          {
            id,
            state: displayValue(item.state),
            kind: displayValue(item.trigger_kind ?? item.step_kind ?? item.kind),
            workflowId: displayValue(item.workflow_id)
          }
        ]
      : []
  })
}

function unique<T extends { id: string }>(values: T[]): T[] {
  return [...new Map(values.map((value) => [value.id, value])).values()]
}

function action(value: unknown): Action | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.action)
  return name
    ? {
        action: name,
        reason: displayValue(value.reason),
        runId: displayValue(value.run_id),
        workflowId: displayValue(value.workflow_id),
        prNumber: displayValue(value.pr_number),
        workUnitId: displayValue(value.work_unit_id),
        nextCheckAt: displayValue(value.next_check_at)
      }
    : null
}

function intent(value: unknown): Intent | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  return id
    ? {
        id,
        kind: displayValue(value.kind),
        state: displayValue(value.state),
        waitReason: displayValue(value.wait_reason),
        waitUntil: displayValue(value.wait_until)
      }
    : null
}

function workUnits(value: unknown): WorkUnit[] {
  if (!isPlainObject(value)) return []
  const source = [...(Array.isArray(value.active) ? value.active : []), ...(Array.isArray(value.recent) ? value.recent : [])]
  return unique(
    source.flatMap((item) => {
      if (!isPlainObject(item)) return []
      const id = displayValue(item.id)
      return id
        ? [
            {
              id,
              state: displayValue(item.state),
              kind: displayValue(item.kind),
              workflowId: displayValue(item.workflow_id),
              blockedReason: displayValue(item.blocked_reason)
            }
          ]
        : []
    })
  )
}

function dependencies(value: unknown): Dependency[] {
  if (!isPlainObject(value)) return []
  const items = [value.pending, value.unsatisfied, value.multiple_leaf_dependencies].flatMap((group) => (Array.isArray(group) ? group : []))
  const parsed = items.flatMap((item, index) => {
    if (!isPlainObject(item)) return []
    const jobId = displayValue(item.job_id),
      epicId = displayValue(item.epic_id),
      unresolved = displayValue(item.unresolved_ref)
    const key = jobId ? `job-${jobId}` : epicId ? `epic-${epicId}` : unresolved ? `pending-${unresolved}` : `dependency-${index}`
    return [{ key, jobId, epicId, unresolved, slug: displayValue(item.slug), state: displayValue(item.state) }]
  })
  return [...new Map(parsed.map((item) => [item.key, item])).values()]
}

function landing(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const mergeability = isPlainObject(value.mergeability) ? value.mergeability : null
  const bits = [
    mergeability?.github_state != null ? `GitHub: ${displayValue(mergeability.github_state)}` : null,
    mergeability?.local_state != null ? `local: ${displayValue(mergeability.local_state)}` : null,
    isPlainObject(value.pr_checks) && value.pr_checks.state != null ? `checks: ${displayValue(value.pr_checks.state)}` : null,
    typeof value.commits_behind_base === "number" ? `${value.commits_behind_base} commits behind base` : null,
    displayValue(value.landing_failure_reason) ? `failure: ${displayValue(value.landing_failure_reason)}` : null
  ].filter((bit): bit is string => Boolean(bit))
  return bits.length ? bits.join(" · ") : null
}

function parse(context: ToolCardContext): Card | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null
  const jobId = displayValue(parsed.job.id),
    state = displayValue(parsed.job.state)
  if (!jobId || !state) return null
  const workflowGroups = isPlainObject(parsed.workflows) ? parsed.workflows : null
  const runGroups = isPlainObject(parsed.runs) ? parsed.runs : null
  const stuckList = isPlainObject(parsed.stuck_list) ? parsed.stuck_list : null
  return {
    jobId,
    state,
    slug: displayValue(parsed.job.slug),
    title: displayValue(parsed.job.issue_title ?? parsed.job.title),
    stuck: parsed.stuck === true,
    branch: displayValue(parsed.job.branch_name),
    prNumber: displayValue(parsed.job.pr_number),
    prUrl: displayValue(parsed.job.pr_url),
    closureReason: displayValue(parsed.job.closure_reason),
    landingFailure: displayValue(parsed.job.landing_failure_reason),
    action: action(parsed.recommended_action),
    summary: displayValue(parsed.human_summary),
    issues: diagnostics(parsed.issues),
    stuckItems: diagnostics(stuckList?.items),
    intent: intent(parsed.current_intent),
    workflows: unique([...refs(workflowGroups?.latest), ...refs(workflowGroups?.active), ...refs(workflowGroups?.queued), ...refs(workflowGroups?.failed)]),
    runs: unique([...refs(runGroups?.latest), ...refs(runGroups?.active), ...refs(runGroups?.failed)]),
    dependencies: dependencies(parsed.dependencies),
    workUnits: workUnits(parsed.work_units),
    landing: landing(parsed.landing)
  }
}

function errorMessage(context: ToolCardContext) {
  if (isPlainObject(context.parsedResult))
    return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message) ?? context.resultBody.trim()
  return context.resultBody.trim()
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return "Could not explain stuck Job"
  const card = parse(context)
  return card ? `${card.slug || `JOB-${card.jobId}`}: ${card.stuck ? "stuck" : "not stuck"}` : null
}

function Detail({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded border border-border bg-surface px-2 py-1">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">{label}</summary>
      <div className="mt-2 space-y-2 text-text-primary">{children}</div>
    </details>
  )
}

function DiagnosticList({ items, jobId }: { items: Diagnostic[]; jobId: string }) {
  return (
    <ul className="space-y-2">
      {items.map((item) => (
        <li className="min-w-0 rounded border border-border bg-surface-raised p-2" key={item.key}>
          <div className="flex flex-wrap items-center gap-2">
            <span className="break-words font-medium">{item.kind.replace(/_/g, " ")}</span>
            {item.severity ? <Badge>{item.severity}</Badge> : null}
            {item.attention ? <StatePill state={item.attention} /> : null}
            {item.workflowId ? <EntityReference id={item.workflowId} jobId={jobId} kind="workflow" /> : null}
            {item.runId ? <EntityReference id={item.runId} jobId={jobId} kind="run" workflowId={item.workflowId} /> : null}
          </div>
          {item.detail ? <MarkdownPreview maxLines={3} text={item.detail} title="Detail" /> : null}
          {item.repair ? <Row label="Repair plan" value={item.repair.replace(/_/g, " ")} /> : null}
        </li>
      ))}
    </ul>
  )
}

function ReferenceList({ items, jobId, type }: { items: Ref[]; jobId: string; type: "workflow" | "run" }) {
  return items.length ? (
    <ul className="space-y-1">
      {items.map((item) => (
        <li className="flex flex-wrap items-center gap-2" key={item.id}>
          <EntityReference id={item.id} jobId={jobId} kind={type} workflowId={type === "run" ? item.workflowId : undefined} />
          {item.state ? <StatePill state={item.state} /> : null}
          {item.kind ? <Badge>{item.kind}</Badge> : null}
        </li>
      ))}
    </ul>
  ) : (
    <EmptyState>No {type === "run" ? "Runs" : "Workflows"} reported.</EmptyState>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <EmptyState>{errorMessage(context) || "Unable to explain this Job."}</EmptyState>
  const card = parse(context)
  if (!card) return context.resultSettled && !context.resultBody.trim() ? <EmptyState>No diagnosis was returned.</EmptyState> : null
  const noDetails =
    !card.issues.length &&
    !card.stuckItems.length &&
    !card.intent &&
    !card.workflows.length &&
    !card.runs.length &&
    !card.dependencies.length &&
    !card.workUnits.length &&
    !card.landing
  const actionWorkflowId = card.action?.workflowId ?? card.runs.find((run) => run.id === card.action?.runId)?.workflowId ?? null
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={card.jobId} kind="job" label={card.slug} slug={card.slug} />
        <StatePill state={card.state} />
        <StatePill state={card.stuck ? "stuck" : "not stuck"} tone={card.stuck ? "failure" : "success"} />
      </div>
      {card.title ? <div className="break-words text-sm font-medium text-text-primary">{card.title}</div> : null}
      {card.branch || card.prNumber || card.closureReason || card.landingFailure ? (
        <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
          {card.branch ? <Row label="Branch" value={card.branch} wrap /> : null}
          {card.prNumber ? (
            <div>
              <SectionLabel>Pull request</SectionLabel>
              <EntityReference id={card.prNumber} kind="pull_request" prUrl={card.prUrl} />
            </div>
          ) : null}
          {card.closureReason ? <Row label="Closure reason" value={card.closureReason} /> : null}
          {card.landingFailure ? <Row label="Landing failure" value={card.landingFailure} /> : null}
        </dl>
      ) : null}
      {card.action ? (
        <div className="rounded border border-border bg-surface-raised p-2">
          <Row label="Recommended action" value={card.action.action.replace(/_/g, " ")} />
          {card.action.reason ? <MarkdownPreview maxLines={3} text={card.action.reason} title="Reason" /> : null}
          <div className="mt-2 flex flex-wrap items-center gap-2">
            {card.action.workflowId ? <EntityReference id={card.action.workflowId} jobId={card.jobId} kind="workflow" /> : null}
            {card.action.runId ? <EntityReference id={card.action.runId} jobId={card.jobId} kind="run" workflowId={actionWorkflowId} /> : null}
            {card.action.prNumber ? <EntityReference id={card.action.prNumber} kind="pull_request" prUrl={card.prUrl} /> : null}
            {card.action.workUnitId ? <InternalLink href={`/admin/work_units?job_id=${card.jobId}`}>WorkUnit {card.action.workUnitId}</InternalLink> : null}
            {card.action.nextCheckAt ? <span className="break-words text-xs text-text-muted">Next check: {card.action.nextCheckAt}</span> : null}
          </div>
        </div>
      ) : null}
      {card.summary ? <MarkdownPreview maxLines={4} text={card.summary} title="Summary" /> : null}
      {card.issues.length ? (
        <Detail label={`Issues (${card.issues.length})`}>
          <DiagnosticList items={card.issues} jobId={card.jobId} />
        </Detail>
      ) : null}
      {card.stuckItems.length ? (
        <Detail label={`Stuck reasons (${card.stuckItems.length})`}>
          <DiagnosticList items={card.stuckItems} jobId={card.jobId} />
        </Detail>
      ) : null}
      {card.intent ? (
        <Detail label="Current intent">
          <div className="flex flex-wrap items-center gap-2">
            <InternalLink href={`/admin/work_units?job_id=${card.jobId}`}>Intent {card.intent.id}</InternalLink>
            {card.intent.state ? <StatePill state={card.intent.state} /> : null}
            {card.intent.kind ? <Badge>{card.intent.kind}</Badge> : null}
          </div>
          {card.intent.waitReason ? <Row label="Wait reason" value={card.intent.waitReason} /> : null}
          {card.intent.waitUntil ? <Row label="Wait until" value={card.intent.waitUntil} /> : null}
        </Detail>
      ) : null}
      <Detail label={`Workflows (${card.workflows.length})`}>
        <ReferenceList items={card.workflows} jobId={card.jobId} type="workflow" />
      </Detail>
      <Detail label={`Runs (${card.runs.length})`}>
        <ReferenceList items={card.runs} jobId={card.jobId} type="run" />
      </Detail>
      {card.dependencies.length ? (
        <Detail label={`Dependencies (${card.dependencies.length})`}>
          <ul className="space-y-1">
            {card.dependencies.map((item) => (
              <li className="flex flex-wrap items-center gap-2" key={item.key}>
                {item.jobId ? (
                  <EntityReference id={item.jobId} kind="job" slug={item.slug} />
                ) : item.epicId ? (
                  <EntityReference id={item.epicId} kind="epic" />
                ) : (
                  <span className="break-words font-mono">{item.unresolved ?? "Unresolved dependency"}</span>
                )}
                {item.state ? <StatePill state={item.state} /> : null}
              </li>
            ))}
          </ul>
        </Detail>
      ) : null}
      {card.workUnits.length ? (
        <Detail label={`Work units (${card.workUnits.length})`}>
          <ul className="space-y-1">
            {card.workUnits.map((item) => (
              <li className="flex flex-wrap items-center gap-2" key={item.id}>
                <InternalLink href={`/admin/work_units?job_id=${card.jobId}`}>WorkUnit {item.id}</InternalLink>
                {item.state ? <StatePill state={item.state} /> : null}
                {item.kind ? <Badge>{item.kind}</Badge> : null}
                {item.blockedReason ? <span className="break-words">{item.blockedReason}</span> : null}
              </li>
            ))}
          </ul>
        </Detail>
      ) : null}
      {card.landing ? (
        <Detail label="Landing">
          <div className="break-words">{card.landing}</div>
        </Detail>
      ) : null}
      {noDetails ? <EmptyState>No additional diagnostic details were returned.</EmptyState> : null}
    </CardShell>
  )
}

const explainStuckJobToolCard: ToolCardRenderer = { toolName: "explain_stuck_job", collapsedSummary, renderExpanded }
export default explainStuckJobToolCard

export const examples: ToolCardExample[] = [
  {
    id: "stale_run_with_repair",
    label: "Stale Run with repair guidance",
    input: { job_id: 5 },
    parsedResult: {
      job: {
        id: 5,
        slug: "JOB-5",
        state: "running",
        title: "Recover stalled work",
        branch_name: "syrus/recover-stalled-work",
        pr_number: 42,
        pr_url: "https://github.com/acme/widget/pull/42"
      },
      stuck: true,
      issues: [
        {
          kind: "running_run_without_live_worker_evidence",
          severity: "high",
          detail: "The **worker heartbeat** is stale.",
          workflow_id: 3,
          run_id: 9,
          repair_plan: { action: "mark_worker_died_and_retry" }
        }
      ],
      stuck_list: {
        listed: true,
        items: [{ kind: "running_run_without_live_worker_evidence", severity: "high", detail: "No live worker owns this Run.", workflow_id: 3, run_id: 9 }]
      },
      current_intent: { id: 11, kind: "initial", state: "waiting", wait_reason: "worker unavailable" },
      work_units: { active: [{ id: 15, kind: "initial", state: "blocked", blocked_reason: "no capable worker" }], recent: [] },
      workflows: { latest: { id: 3, state: "running", trigger_kind: "initial" } },
      runs: { latest: { id: 9, workflow_id: 3, state: "running", step_kind: "implement" } },
      dependencies: { unsatisfied: [{ job_id: 4, slug: "JOB-4", state: "landing" }] },
      landing: { pr_checks: { state: "pending" }, commits_behind_base: 1 },
      recommended_action: {
        action: "inspect_logs",
        reason: "Inspect the **complete Run log** before retrying. ".repeat(35),
        run_id: 9,
        pr_number: 42,
        work_unit_id: 15,
        next_check_at: "2026-10-23T12:30:00Z"
      },
      human_summary: "The Job is **stuck** because its active Run no longer has live worker evidence."
    }
  },
  {
    id: "healthy_without_diagnostics",
    label: "Not stuck, without diagnostic history",
    input: { job_id: 8 },
    parsedResult: { job: { id: 8, state: "implemented", title: "Completed work" }, stuck: false }
  },
  { id: "authorization_error", label: "Authorization error", input: { job_id: 999 }, parsedResult: { error: "not_authorized" }, resultError: true }
]

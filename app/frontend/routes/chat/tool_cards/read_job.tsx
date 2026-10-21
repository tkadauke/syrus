import { workerCapabilitiesText } from "../../../lib/workerCapabilities"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type WorkflowRow = { id: string; state: string; triggerKind: string | null; summary: string | null }
type Dependency = { key: string; id: string | null; kind: "job" | "epic" | null; label: string; state: string | null; pending: boolean; detail: string | null }
type Stage = { name: string; label: string; reached: boolean }
type Transcript = { head: string; tail: string; truncated: boolean; totalChunks: string | null; sampledChunks: string | null }
type JobCard = {
  id: string
  title: string
  state: string
  prNumber: string | null
  repository: string | null
  branch: string | null
  priority: string | null
  provider: string | null
  closureReason: string | null
  landedSha: string | null
  commitsBehind: string | null
  execution: string | null
  goalChatId: string | null
  goalPrompt: string | null
  approvalEvidence: string | null
  invalidationEvidence: string | null
  landingOverride: string | null
  dependencies: Dependency[]
  stages: Stage[]
  latestWorkflow: WorkflowRow | null
  workflows: WorkflowRow[]
  workflowCount: string | null
  transcript: Transcript | null
}

const failureConfig: ToolFailureConfig = {
  title: "Job read",
  attempted: (context) => (stringFromInput(context, ["job_id"]) ? `Read JOB-${stringFromInput(context, ["job_id"])}` : "Read Job"),
  retrySafety: "unknown",
  recovery: "Check that the Job exists and is accessible, then retry."
}

function jsonDetail(value: unknown) {
  if (value == null) return null
  if (typeof value === "string") return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return displayValue(value)
  }
}

function executionDetail(value: unknown) {
  if (!isPlainObject(value)) return null
  const parts = [displayValue(value.project), displayValue(value.target_label), workerCapabilitiesText(value.capabilities)].filter(Boolean)
  return parts.length ? parts.join(" · ") : jsonDetail(value)
}

function workflowRow(value: unknown): WorkflowRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id),
    state = displayValue(value.state)
  return id && state ? { id, state, triggerKind: displayValue(value.trigger_kind), summary: displayValue(value.summary) } : null
}

function dependencies(value: unknown): Dependency[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    if (!isPlainObject(item)) return []
    const pending = item.pending === true,
      epic = item.epic_id !== undefined
    const id = displayValue(epic ? item.epic_id : item.id)
    const label = pending
      ? displayValue(item.unresolved_ref) || "pending dependency"
      : epic
        ? displayValue(item.display_number) || `EPIC-${id}`
        : id
          ? `JOB-${id}`
          : null
    if (!label) return []
    const mode = displayValue(item.satisfaction_mode),
      stage = displayValue(item.required_deployment_stage_name)
    const latest = isPlainObject(item.latest_deployment_stage)
      ? displayValue(item.latest_deployment_stage.label) || displayValue(item.latest_deployment_stage.name)
      : null
    return [
      {
        key: `${label}-${index}`,
        id,
        kind: pending ? null : epic ? "epic" : "job",
        label,
        state: displayValue(pending ? item.unresolved_ref_state : item.state),
        pending,
        detail: mode === "deployment_stage" ? `stage ${stage || "unspecified"}${latest ? ` · latest ${latest}` : ""}` : mode
      }
    ]
  })
}

function stages(value: unknown): Stage[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const name = displayValue(item.name)
    return name ? [{ name, label: displayValue(item.label) || name, reached: item.reached === true }] : []
  })
}

function parseTranscript(value: unknown): Transcript | null {
  if (!isPlainObject(value)) return null
  return {
    head: typeof value.head === "string" ? value.head : "",
    tail: typeof value.tail === "string" ? value.tail : "",
    truncated: value.truncated === true,
    totalChunks: displayValue(value.total_chunks),
    sampledChunks: displayValue(value.sampled_chunks)
  }
}

function parseJob(context: ToolCardContext): JobCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null
  const job = parsed.job,
    id = displayValue(job.id),
    state = displayValue(job.state)
  if (!id || !state) return null
  const provenance = isPlainObject(job.goal_provenance) ? job.goal_provenance : null
  const prompt = provenance && isPlainObject(provenance.prompt_snapshot) ? provenance.prompt_snapshot : null
  const requestedBy = isPlainObject(job.landing_blocker_override_requested_by) ? job.landing_blocker_override_requested_by : null
  const override = [
    displayValue(job.landing_blocker_override_requested_at),
    requestedBy && (displayValue(requestedBy.display_name) || displayValue(requestedBy.email_address))
  ].filter(Boolean)
  return {
    id,
    state,
    title: displayValue(job.issue_title) || `JOB-${id}`,
    prNumber: displayValue(job.pr_number),
    repository: displayValue(job.repository_slug),
    branch: displayValue(job.branch_name),
    priority: displayValue(job.priority),
    provider: displayValue(job.agent_provider),
    closureReason: displayValue(job.closure_reason),
    landedSha: displayValue(job.landed_sha),
    commitsBehind: displayValue(job.commits_behind_base),
    execution: executionDetail(job.planned_execution),
    goalChatId: provenance ? displayValue(provenance.chat_goal_id) : null,
    goalPrompt: prompt ? displayValue(prompt.prompt) : null,
    approvalEvidence: jsonDetail(job.approval_evidence),
    invalidationEvidence: jsonDetail(job.invalidation_evidence),
    landingOverride: override.length ? override.join(" · ") : null,
    dependencies: dependencies(job.dependencies),
    stages: stages(job.deployment_stages),
    latestWorkflow: workflowRow(parsed.latest_workflow),
    workflows: Array.isArray(parsed.workflows_index) ? parsed.workflows_index.flatMap((value) => workflowRow(value) || []) : [],
    workflowCount: displayValue(parsed.workflow_count),
    transcript: parseTranscript(parsed.transcript)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const job = parseJob(context)
  if (job) return `JOB-${job.id} (${job.state})`
  const requested = stringFromInput(context, ["job_id"])
  return context.parsedResult == null && !context.resultBody ? `Reading ${requested ? `JOB-${requested}` : "Job"}…` : null
}

function WorkflowSummary({ jobId, workflow, title }: { jobId: string; workflow: WorkflowRow; title: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{title}</SectionLabel>
      <div className="mt-1 flex flex-wrap items-center gap-2">
        <EntityReference id={workflow.id} jobId={jobId} kind="workflow" />
        <StatePill state={workflow.state} />
        {workflow.triggerKind ? <Badge>{workflow.triggerKind}</Badge> : null}
      </div>
      {workflow.summary ? <MarkdownPreview maxLines={4} modalLabel={`WF-${workflow.id} summary`} text={workflow.summary} /> : null}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const job = parseJob(context)
  if (!job) return context.parsedResult == null && !context.resultBody ? <EmptyState>Waiting for Job details.</EmptyState> : null
  const repoUrl = job.repository ? `https://github.com/${job.repository.split("/").map(encodeURIComponent).join("/")}` : null
  const prUrl = job.prNumber && repoUrl ? `${repoUrl}/pull/${encodeURIComponent(job.prNumber)}` : null
  const transcriptText = job.transcript ? [job.transcript.head, job.transcript.tail].filter(Boolean).join(job.transcript.truncated ? "\n\n…\n\n" : "") : ""
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={job.id} kind="job" />
        <StatePill state={job.state} />
        {job.priority ? <Badge>{job.priority} priority</Badge> : null}
        {job.provider ? <Badge>{job.provider}</Badge> : null}
      </div>
      <div className="break-words text-sm font-medium text-text-primary">{job.title}</div>
      <dl className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {job.repository ? (
          <div>
            <SectionLabel>Repository</SectionLabel>
            <EntityReference href={repoUrl} kind="repository" repositorySlug={job.repository} />
          </div>
        ) : null}
        {job.prNumber ? (
          <div>
            <SectionLabel>PR</SectionLabel>
            <EntityReference id={job.prNumber} kind="pull_request" prUrl={prUrl} />
          </div>
        ) : null}
        {job.branch ? <Row label="Branch" value={job.branch} wrap /> : null}
        {job.closureReason ? <Row label="Closure reason" value={job.closureReason} /> : null}
        {job.landedSha ? <Row label="Landed SHA" value={job.landedSha} wrap /> : null}
        {job.commitsBehind ? <Row label="Commits behind base" value={job.commitsBehind} /> : null}
        {job.execution ? <Row label="Planned execution" value={job.execution} /> : null}
        {job.goalChatId ? (
          <div>
            <SectionLabel>Goal provenance</SectionLabel>
            <EntityReference id={job.goalChatId} kind="chat" />
          </div>
        ) : null}
      </dl>
      {job.goalPrompt ? <MarkdownPreview maxLines={3} text={job.goalPrompt} title="Goal prompt" /> : null}
      {job.latestWorkflow ? (
        <WorkflowSummary jobId={job.id} title="Latest workflow" workflow={job.latestWorkflow} />
      ) : (
        <EmptyState>No Workflows found.</EmptyState>
      )}
      {job.workflows.length ? (
        <div>
          <SectionLabel>Workflow history ({job.workflowCount || job.workflows.length})</SectionLabel>
          <div className="mt-1 space-y-2">
            {job.workflows.map((workflow) => (
              <WorkflowSummary jobId={job.id} key={workflow.id} title={`WF-${workflow.id}`} workflow={workflow} />
            ))}
          </div>
        </div>
      ) : null}
      {job.transcript ? (
        <div>
          <MarkdownPreview maxLines={6} modalLabel="Workflow transcript" text={transcriptText} title="Transcript" />
          {job.transcript.totalChunks ? (
            <div className="mt-1 text-2xs text-text-muted">
              {job.transcript.sampledChunks || job.transcript.totalChunks} of {job.transcript.totalChunks} chunks shown
              {job.transcript.truncated ? " · truncated" : ""}
            </div>
          ) : null}
        </div>
      ) : null}
      {job.dependencies.length ? (
        <div>
          <SectionLabel>Dependencies</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {job.dependencies.map((dependency) => (
              <span
                className={`rounded-full px-2 py-0.5 text-2xs ${dependency.pending ? "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}
                key={dependency.key}
              >
                {dependency.kind ? (
                  <EntityReference id={dependency.id} kind={dependency.kind} label={dependency.label} slug={dependency.label} />
                ) : (
                  dependency.label
                )}
                {dependency.state ? ` · ${dependency.state}` : ""}
                {dependency.detail ? ` · ${dependency.detail}` : ""}
              </span>
            ))}
          </div>
        </div>
      ) : null}
      {job.stages.length ? (
        <div>
          <SectionLabel>Deployment stage</SectionLabel>
          <div className="mt-1 flex flex-wrap items-center gap-1">
            {job.stages.map((stage, index) => (
              <span className="flex items-center gap-1" key={stage.name}>
                <span
                  className={`rounded-full px-2 py-0.5 text-2xs ${stage.reached ? "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-200" : "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"}`}
                >
                  {stage.label}
                </span>
                {index < job.stages.length - 1 ? <span aria-hidden>→</span> : null}
              </span>
            ))}
          </div>
        </div>
      ) : null}
      {job.approvalEvidence ? <Row label="Approval evidence" value={job.approvalEvidence} /> : null}
      {job.invalidationEvidence ? <Row label="Invalidation evidence" value={job.invalidationEvidence} /> : null}
      {job.landingOverride ? <Row label="Landing override requested" value={job.landingOverride} /> : null}
    </CardShell>
  )
}

const readJobToolCard: ToolCardRenderer = { toolName: "read_job", collapsedSummary, renderExpanded }
export default readJobToolCard

export const examples: ToolCardExample[] = [
  {
    id: "complete_job",
    label: "Job with workflow, transcript, and audit details",
    input: { job_id: 71 },
    parsedResult: {
      job: {
        id: 71,
        issue_title: "Improve Job details",
        state: "running",
        repository_slug: "tkadauke/syrus",
        pr_number: 407,
        branch_name: "syrus/issue-71-with-a-long-responsive-branch-name",
        priority: "medium",
        agent_provider: "codex",
        planned_execution: { project: "repo", target_label: "//:test", capabilities: { os: ["linux"] } },
        goal_provenance: { chat_goal_id: 12, prompt_snapshot: { prompt: "Ship the **complete** tool card." } },
        approval_evidence: { rule: "if_graders_pass" }
      },
      workflow_count: 2,
      latest_workflow: { id: 91, state: "running", trigger_kind: "initial", summary: "Implemented **most** of the requested behavior. ".repeat(20) },
      workflows_index: [
        { id: 91, state: "running", trigger_kind: "initial", summary: "Current attempt" },
        { id: 90, state: "failed", trigger_kind: "retry", summary: "Earlier attempt" }
      ],
      transcript: { head: "Starting work\n", tail: "Tests passing\n", truncated: true, total_chunks: 42, sampled_chunks: 40 }
    }
  },
  { id: "not_found", label: "Job not found", input: { job_id: 999999 }, resultError: true, parsedResult: { error: "Job not found" } },
  { id: "missing_input", label: "Missing input while loading", input: {}, resultBody: "", parsedResult: null }
]

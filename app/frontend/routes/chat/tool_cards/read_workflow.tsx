import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import {
  Badge,
  CardShell,
  decimalCost,
  displayValue,
  durationLabel,
  EmptyState,
  EntityReference,
  numberValue,
  Row,
  SectionLabel,
  StatePill
} from "../toolCardUi"

// Core-owned tool card for read_workflow (the Tier 1 tool-card work). Renders the
// Workflow header plus a Step/Run timeline: state, duration/timestamps,
// trigger kind, summary, and cost when present.
type RunEntry = {
  key: string
  id: string
  state: string
  agentOutcome: string | null
  agentSummary: string | null
  duration: string | null
  cost: string | null
}

type StepEntry = {
  key: string
  id: string
  kind: string
  state: string
  position: number | null
  details: string | null
  runCount: number
  duration: string | null
  runs: RunEntry[]
}

type WorkflowCard = {
  id: string
  jobId: string | null
  triggerKind: string | null
  state: string
  agentProvider: string | null
  summary: string | null
  stepCount: number
  runCount: number
  totalCost: string | null
  duration: string | null
  createdAt: string | null
  steps: StepEntry[]
}

type WorkflowResult = { kind: "workflow"; workflow: WorkflowCard } | { kind: "error"; workflowId: string | null; message: string }

function parseRun(value: unknown): RunEntry | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    id,
    state,
    agentOutcome: displayValue(value.agent_outcome),
    agentSummary: displayValue(value.agent_summary),
    duration: durationLabel(value.started_at, value.finished_at),
    cost: decimalCost(value.cost_usd)
  }
}

function parseStep(value: unknown): StepEntry | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const kind = displayValue(value.kind)
  const state = displayValue(value.state)
  if (!id || !kind || !state) return null

  const runs = Array.isArray(value.runs)
    ? value.runs.flatMap((run) => {
        const parsed = parseRun(run)
        return parsed ? [parsed] : []
      })
    : []

  return {
    key: id,
    id,
    kind,
    state,
    position: numberValue(value.position),
    details: displayValue(value.details),
    runCount: numberValue(value.run_count) ?? runs.length,
    duration: durationLabel(value.started_at, value.finished_at),
    runs
  }
}

function errorMessage(context: ToolCardContext) {
  const parsed = context.parsedResult
  if (isPlainObject(parsed))
    return displayValue(parsed.error) ?? displayValue(parsed.message) ?? displayValue(context.resultBody) ?? "Workflow could not be read."
  return displayValue(context.resultBody) ?? "Workflow could not be read."
}

function parseResult(context: ToolCardContext): WorkflowResult | null {
  if (context.resultError) {
    return { kind: "error", workflowId: displayValue(context.input?.workflow_id), message: errorMessage(context) }
  }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.workflow)) return null

  const workflow = parsed.workflow
  const id = displayValue(workflow.id)
  const state = displayValue(workflow.state)
  if (!id || !state) return null

  const steps = Array.isArray(workflow.steps)
    ? workflow.steps.flatMap((step) => {
        const parsed = parseStep(step)
        return parsed ? [parsed] : []
      })
    : []

  return {
    kind: "workflow",
    workflow: {
      id,
      jobId: displayValue(workflow.job_id),
      triggerKind: displayValue(workflow.trigger_kind),
      state,
      agentProvider: displayValue(workflow.agent_provider),
      summary: displayValue(workflow.summary),
      stepCount: numberValue(workflow.step_count) ?? steps.length,
      runCount: numberValue(workflow.run_count) ?? steps.reduce((total, step) => total + step.runCount, 0),
      totalCost: decimalCost(workflow.total_cost_usd),
      duration: durationLabel(workflow.started_at, workflow.finished_at),
      createdAt: displayValue(workflow.created_at),
      steps
    }
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.kind === "error") return result.workflowId ? `WF-${result.workflowId} could not be read` : "Workflow could not be read"
  const workflow = result.workflow
  return `WF-${workflow.id} (${workflow.state})`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.kind === "error") {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          {result.workflowId ? <EntityReference id={result.workflowId} kind="workflow" /> : null}
          <StatePill state="failed" tone="failure" />
        </div>
        <div className="break-words rounded border border-danger-border bg-danger-surface px-2 py-1 text-danger-text">{result.message}</div>
      </CardShell>
    )
  }

  const workflow = result.workflow

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={workflow.id} jobId={workflow.jobId} kind="workflow" />
        <StatePill state={workflow.state} />
        {workflow.triggerKind ? <Badge>{workflow.triggerKind}</Badge> : null}
        {workflow.agentProvider ? <Badge>{workflow.agentProvider}</Badge> : null}
        {workflow.totalCost ? <Badge>{workflow.totalCost}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {workflow.jobId ? (
          <div className="min-w-0">
            <SectionLabel>Job</SectionLabel>
            <EntityReference id={workflow.jobId} kind="job" />
          </div>
        ) : null}
        {workflow.duration ? <Row label="Duration" value={workflow.duration} /> : null}
        {workflow.createdAt ? <Row label="Created" value={workflow.createdAt} /> : null}
        <Row label="Steps" value={String(workflow.stepCount)} />
        <Row label="Runs" value={String(workflow.runCount)} />
      </dl>
      {workflow.summary ? <MarkdownPreview modalLabel={`Full summary for WF-${workflow.id}`} text={workflow.summary} title="Summary" /> : null}
      {workflow.steps.length > 0 ? (
        <div>
          <SectionLabel>Steps</SectionLabel>
          <ol className="mt-1 space-y-2 border-l border-border pl-3">
            {workflow.steps.map((step) => (
              <li key={step.key}>
                <div className="flex flex-wrap items-center gap-2">
                  {step.position != null ? <span className="shrink-0 font-mono text-2xs text-text-muted">#{step.position}</span> : null}
                  <span className="font-mono font-medium text-text-primary">{step.kind}</span>
                  <StatePill state={step.state} />
                  <Badge>
                    {step.runCount} run{step.runCount === 1 ? "" : "s"}
                  </Badge>
                  {step.duration ? <span className="text-2xs text-text-muted">{step.duration}</span> : null}
                </div>
                {step.details ? (
                  <div className="mt-1 whitespace-pre-wrap break-words text-xs text-text-secondary [overflow-wrap:anywhere]">{step.details}</div>
                ) : null}
                {step.runs.length > 0 ? (
                  <ul className="mt-1 min-w-0 space-y-2 pl-3">
                    {step.runs.map((run) => (
                      <li className="min-w-0 text-2xs text-text-secondary" key={run.key}>
                        <div className="flex min-w-0 flex-wrap items-center gap-2">
                          <EntityReference id={run.id} jobId={workflow.jobId} kind="run" workflowId={workflow.id} />
                          <StatePill state={run.state} />
                          {run.agentOutcome ? <Badge>{run.agentOutcome}</Badge> : null}
                          {run.cost ? <span>{run.cost}</span> : null}
                          {run.duration ? <span>{run.duration}</span> : null}
                        </div>
                        {run.agentSummary ? (
                          <div className="mt-1 min-w-0">
                            <MarkdownPreview maxLines={3} modalLabel={`Full summary for RUN-${run.id}`} text={run.agentSummary} />
                          </div>
                        ) : null}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            ))}
          </ol>
        </div>
      ) : (
        <EmptyState>This workflow has no steps.</EmptyState>
      )}
    </CardShell>
  )
}

const readWorkflowToolCard: ToolCardRenderer = {
  toolName: "read_workflow",
  collapsedSummary,
  renderExpanded
}

export default readWorkflowToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample.
export const examples = [
  {
    id: "workflow_with_run_timeline",
    label: "Workflow with Run timeline",
    input: { workflow_id: 25606 },
    parsedResult: {
      workflow: {
        id: 25606,
        job_id: 4221,
        trigger_kind: "initial",
        state: "running",
        agent_provider: "codex",
        summary: "## Tool card update\n\nAdding linked entity refs and responsive Markdown summaries.",
        step_count: 1,
        run_count: 1,
        total_cost_usd: "1.75",
        created_at: "2025-12-31T23:59:00Z",
        started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:05:00Z",
        steps: [
          {
            id: 1,
            kind: "implement",
            state: "succeeded",
            position: 0,
            details: "Implement and verify the workflow card.",
            run_count: 1,
            started_at: "2026-01-01T00:00:00Z",
            finished_at: "2026-01-01T00:02:00Z",
            runs: [
              {
                id: 9,
                state: "succeeded",
                agent_outcome: "success",
                agent_summary: "**Updated** the card and its tests.",
                started_at: "2026-01-01T00:00:00Z",
                finished_at: "2026-01-01T00:02:00Z",
                cost_usd: "0.42"
              }
            ]
          }
        ]
      }
    }
  },
  {
    id: "queued_workflow_without_steps",
    label: "Queued Workflow without Steps or Job link",
    description: "Shows the explicit empty state; without job_id, the workflow slug remains copyable without a derived route.",
    input: { workflow_id: 25607 },
    parsedResult: { workflow: { id: 25607, state: "queued", trigger_kind: "retry", step_count: 0, run_count: 0, steps: [] } }
  },
  {
    id: "inaccessible_workflow",
    label: "Inaccessible Workflow",
    input: { workflow_id: 99999 },
    resultBody: "Workflow is inaccessible or was not found.",
    resultError: true
  }
]

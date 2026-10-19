import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, decimalCost, displayValue, durationLabel, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"

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
  position: string | null
  details: string | null
  runCount: string | null
  createdAt: string | null
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
  stepCount: string | null
  runCount: string | null
  createdAt: string | null
  totalCost: string | null
  duration: string | null
  steps: StepEntry[]
}

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
    position: displayValue(value.position),
    details: displayValue(value.details),
    runCount: displayValue(value.run_count),
    createdAt: displayValue(value.created_at),
    duration: durationLabel(value.started_at, value.finished_at),
    runs
  }
}

function parseWorkflow(context: ToolCardContext): WorkflowCard | null {
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
    id,
    jobId: displayValue(workflow.job_id),
    triggerKind: displayValue(workflow.trigger_kind),
    state,
    agentProvider: displayValue(workflow.agent_provider),
    summary: displayValue(workflow.summary),
    stepCount: displayValue(workflow.step_count),
    runCount: displayValue(workflow.run_count),
    createdAt: displayValue(workflow.created_at),
    totalCost: decimalCost(workflow.total_cost_usd),
    duration: durationLabel(workflow.started_at, workflow.finished_at),
    steps
  }
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return "Workflow lookup failed"
  const workflow = parseWorkflow(context)
  if (!workflow) return null
  return `WF-${workflow.id} (${workflow.state})`
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) {
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state="failed" /> Workflow lookup failed
        </div>
        {context.input?.workflow_id != null ? <EntityReference id={String(context.input.workflow_id)} kind="workflow" /> : null}
        {context.resultBody ? <div className="break-words text-xs text-red-700 dark:text-red-300 [overflow-wrap:anywhere]">{context.resultBody}</div> : null}
      </CardShell>
    )
  }
  const workflow = parseWorkflow(context)
  if (!workflow) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={workflow.id} jobId={workflow.jobId} kind="workflow" />
        <StatePill state={workflow.state} />
        {workflow.triggerKind ? <Badge>{workflow.triggerKind}</Badge> : null}
        {workflow.agentProvider ? <Badge>{workflow.agentProvider}</Badge> : null}
        {workflow.totalCost ? <Badge>{workflow.totalCost}</Badge> : null}
        {workflow.stepCount ? <Badge>{workflow.stepCount} steps</Badge> : null}
        {workflow.runCount ? <Badge>{workflow.runCount} runs</Badge> : null}
      </div>
      {workflow.jobId || workflow.duration || workflow.createdAt ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {workflow.jobId ? (
            <div className="min-w-0">
              <SectionLabel>Job</SectionLabel>
              <EntityReference id={workflow.jobId} kind="job" />
            </div>
          ) : null}
          {workflow.duration ? <Row label="Duration" value={workflow.duration} /> : null}
          {workflow.createdAt ? <Row label="Created" value={workflow.createdAt} /> : null}
        </dl>
      ) : null}
      {workflow.summary ? <MarkdownPreview maxLines={1} modalLabel="Workflow summary" text={workflow.summary} title="Summary" /> : null}
      {workflow.steps.length > 0 ? (
        <div>
          <SectionLabel>Steps</SectionLabel>
          <ol className="mt-1 space-y-2 border-l border-gray-200 pl-3 dark:border-gray-700">
            {workflow.steps.map((step) => (
              <li key={step.key}>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{step.kind}</span>
                  <StatePill state={step.state} />
                  {step.position ? <Badge>Position {step.position}</Badge> : null}
                  {step.runCount ? <Badge>{step.runCount} runs</Badge> : null}
                  {step.duration ? <span className="text-2xs text-gray-500 dark:text-gray-400">{step.duration}</span> : null}
                </div>
                {step.details ? <MarkdownPreview maxLines={2} modalLabel={`${step.kind} step details`} text={step.details} title="Details" /> : null}
                {step.createdAt ? <div className="text-2xs text-gray-500 dark:text-gray-400">Created {step.createdAt}</div> : null}
                {step.runs.length > 0 ? (
                  <ul className="mt-1 space-y-1 pl-3">
                    {step.runs.map((run) => (
                      <li className="min-w-0 text-2xs text-gray-600 dark:text-gray-300" key={run.key}>
                        <div className="flex min-w-0 flex-wrap items-center gap-2">
                          <EntityReference id={run.id} jobId={workflow.jobId} kind="run" workflowId={workflow.id} />
                          <StatePill state={run.state} />
                          {run.agentOutcome ? <Badge>{run.agentOutcome}</Badge> : null}
                          {run.cost ? <span>{run.cost}</span> : null}
                          {run.duration ? <span>{run.duration}</span> : null}
                        </div>
                        {run.agentSummary ? <MarkdownPreview maxLines={2} modalLabel={`RUN-${run.id} summary`} text={run.agentSummary} /> : null}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            ))}
          </ol>
        </div>
      ) : (
        <EmptyState>No steps have been created for this Workflow.</EmptyState>
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
        summary: "Adding linked entity refs to representative tool cards.",
        total_cost_usd: "1.75",
        started_at: "2026-01-01T00:00:00Z",
        finished_at: "2026-01-01T00:05:00Z",
        steps: [
          {
            id: 1,
            kind: "implement",
            state: "succeeded",
            position: 0,
            details: "Implemented the **workflow card** with responsive Run summaries.",
            run_count: 1,
            started_at: "2026-01-01T00:00:00Z",
            finished_at: "2026-01-01T00:02:00Z",
            runs: [
              {
                id: 9,
                state: "succeeded",
                agent_outcome: "success",
                agent_summary: "Updated the card and its tests.",
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
    id: "queued_workflow_without_job",
    label: "Queued Workflow without Job link",
    description: "No job_id is present, so the workflow slug remains copyable without a derived route.",
    input: { workflow_id: 25607 },
    parsedResult: { workflow: { id: 25607, state: "queued", trigger_kind: "retry" } }
  },
  {
    id: "inaccessible_workflow",
    label: "Inaccessible Workflow error",
    input: { workflow_id: 99999 },
    resultBody: "Workflow not found or inaccessible",
    resultError: true
  }
]

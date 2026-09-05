import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, decimalCost, displayValue, durationLabel, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for read_workflow (EPIC-291 / JOB-4221). Renders the
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

  const runs = Array.isArray(value.runs) ? value.runs.flatMap((run) => { const parsed = parseRun(run); return parsed ? [parsed] : [] }) : []

  return {
    key: id,
    id,
    kind,
    state,
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

  const steps = Array.isArray(workflow.steps) ? workflow.steps.flatMap((step) => { const parsed = parseStep(step); return parsed ? [parsed] : [] }) : []

  return {
    id,
    jobId: displayValue(workflow.job_id),
    triggerKind: displayValue(workflow.trigger_kind),
    state,
    agentProvider: displayValue(workflow.agent_provider),
    summary: displayValue(workflow.summary),
    totalCost: decimalCost(workflow.total_cost_usd),
    duration: durationLabel(workflow.started_at, workflow.finished_at),
    steps
  }
}

function collapsedSummary(context: ToolCardContext) {
  const workflow = parseWorkflow(context)
  if (!workflow) return null
  return `WF-${workflow.id} (${workflow.state})`
}

function renderExpanded(context: ToolCardContext) {
  const workflow = parseWorkflow(context)
  if (!workflow) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">WF-{workflow.id}</span>
        <StatePill state={workflow.state} />
        {workflow.triggerKind ? <Badge>{workflow.triggerKind}</Badge> : null}
        {workflow.agentProvider ? <Badge>{workflow.agentProvider}</Badge> : null}
        {workflow.totalCost ? <Badge>{workflow.totalCost}</Badge> : null}
      </div>
      {workflow.jobId || workflow.duration ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {workflow.jobId ? <Row label="Job" value={`JOB-${workflow.jobId}`} /> : null}
          {workflow.duration ? <Row label="Duration" value={workflow.duration} /> : null}
        </dl>
      ) : null}
      {workflow.summary ? <div className="text-gray-700 dark:text-gray-300">{workflow.summary}</div> : null}
      {workflow.steps.length > 0 ? (
        <div>
          <SectionLabel>Steps</SectionLabel>
          <ol className="mt-1 space-y-2 border-l border-gray-200 pl-3 dark:border-gray-700">
            {workflow.steps.map((step) => (
              <li key={step.key}>
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{step.kind}</span>
                  <StatePill state={step.state} />
                  {step.duration ? <span className="text-2xs text-gray-500 dark:text-gray-400">{step.duration}</span> : null}
                </div>
                {step.runs.length > 0 ? (
                  <ul className="mt-1 space-y-1 pl-3">
                    {step.runs.map((run) => (
                      <li className="flex flex-wrap items-center gap-2 text-2xs text-gray-600 dark:text-gray-300" key={run.key}>
                        <span className="font-mono">RUN-{run.id}</span>
                        <StatePill state={run.state} />
                        {run.agentOutcome ? <Badge>{run.agentOutcome}</Badge> : null}
                        {run.cost ? <span>{run.cost}</span> : null}
                        {run.duration ? <span>{run.duration}</span> : null}
                        {run.agentSummary ? <span className="truncate" title={run.agentSummary}>{run.agentSummary}</span> : null}
                      </li>
                    ))}
                  </ul>
                ) : null}
              </li>
            ))}
          </ol>
        </div>
      ) : null}
    </CardShell>
  )
}

const readWorkflowToolCard: ToolCardRenderer = {
  toolName: "read_workflow",
  collapsedSummary,
  renderExpanded
}

export default readWorkflowToolCard

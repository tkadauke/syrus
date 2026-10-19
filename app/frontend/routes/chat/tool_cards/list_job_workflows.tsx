import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CapabilityBadges, CardShell, displayValue, durationLabel, EmptyState, EntityReference, StatePill } from "../toolCardUi"

type WorkflowRow = {
  key: string
  id: string
  triggerKind: string | null
  state: string
  plannedExecution: Record<string, unknown> | null
  summary: string | null
  stepCount: number | null
  runCount: number | null
  createdAt: string | null
  startedAt: string | null
  finishedAt: string | null
  duration: string | null
}

type WorkflowCard =
  | { kind: "results"; jobId: string | null; rows: WorkflowRow[] }
  | { kind: "error"; jobId: string | null; message: string }
  | { kind: "malformed"; jobId: string | null }

function countValue(value: unknown) {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value)
  return null
}

function parseRow(value: unknown): WorkflowRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null

  return {
    key: id,
    id,
    triggerKind: displayValue(value.trigger_kind),
    state,
    plannedExecution: isPlainObject(value.planned_execution) ? value.planned_execution : null,
    summary: displayValue(value.summary),
    stepCount: countValue(value.step_count),
    runCount: countValue(value.run_count),
    createdAt: displayValue(value.created_at),
    startedAt: displayValue(value.started_at),
    finishedAt: displayValue(value.finished_at),
    duration: durationLabel(value.started_at, value.finished_at)
  }
}

function parseCard(context: ToolCardContext): WorkflowCard {
  const parsed = context.parsedResult
  const resultJobId = isPlainObject(parsed) ? displayValue(parsed.job_id) : null
  const jobId = resultJobId ?? displayValue(context.input?.job_id)

  if (context.resultError) {
    return { kind: "error", jobId, message: displayValue(context.resultBody) ?? "Could not list Job workflows." }
  }
  if (!isPlainObject(parsed) || !Array.isArray(parsed.workflows)) return { kind: "malformed", jobId }

  return {
    kind: "results",
    jobId,
    rows: parsed.workflows.flatMap((workflow) => {
      const row = parseRow(workflow)
      return row ? [row] : []
    })
  }
}

function jobLabel(jobId: string | null) {
  return jobId ? `JOB-${jobId}` : "Job"
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (card.kind === "error") return `${jobLabel(card.jobId)} workflows failed`
  if (card.kind === "malformed") return null
  return `${jobLabel(card.jobId)} · ${card.rows.length} Workflow${card.rows.length === 1 ? "" : "s"}`
}

function Timestamp({ value }: { value: string | null }) {
  if (!value) return <>—</>
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>{value}</>
  return (
    <time dateTime={value} title={date.toLocaleString()}>
      {date.toLocaleString()}
    </time>
  )
}

function PlannedExecution({ value }: { value: Record<string, unknown> | null }) {
  if (!value) return <>—</>
  const project = displayValue(value.project_label)
  const target = displayValue(value.target_label)
  const source = displayValue(value.source)

  return (
    <div className="space-y-1">
      <CapabilityBadges capabilities={value.capabilities} />
      <div className="flex flex-wrap gap-1">
        {project ? <Badge>{project}</Badge> : null}
        {target ? <Badge>{target}</Badge> : null}
        {source ? <Badge>{source}</Badge> : null}
      </div>
    </div>
  )
}

function JobHeader({ jobId }: { jobId: string | null }) {
  return (
    <div className="flex min-h-6 items-center gap-2 font-medium text-text-primary">
      <span>Workflows for</span>
      {jobId ? <EntityReference id={jobId} kind="job" /> : <span>Job</span>}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (card.kind === "malformed") return null

  if (card.kind === "error") {
    return (
      <CardShell>
        <JobHeader jobId={card.jobId} />
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          {card.message}
        </div>
      </CardShell>
    )
  }

  return (
    <CardShell>
      <JobHeader jobId={card.jobId} />
      {card.rows.length === 0 ? (
        <EmptyState>No Workflows found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["Workflow", "Trigger", "State", "Planned execution", "Summary", "Steps / runs", "Created", "Started", "Finished / duration"]} />
          <TBody>
            {card.rows.map((row) => (
              <tr key={row.key}>
                <Td primary>
                  <EntityReference id={row.id} jobId={card.jobId} kind="workflow" wrap="nowrap" />
                </Td>
                <Td>{row.triggerKind ? <Badge>{row.triggerKind}</Badge> : "—"}</Td>
                <Td>
                  <StatePill state={row.state} />
                </Td>
                <Td wrap>
                  <PlannedExecution value={row.plannedExecution} />
                </Td>
                <Td maxWidth wrap>
                  {row.summary ? <MarkdownPreview maxLines={3} modalLabel={`Workflow ${row.id} summary`} text={row.summary} /> : "—"}
                </Td>
                <Td>
                  {row.stepCount ?? "—"} / {row.runCount ?? "—"}
                </Td>
                <Td>
                  <Timestamp value={row.createdAt} />
                </Td>
                <Td>
                  <Timestamp value={row.startedAt} />
                </Td>
                <Td>
                  <Timestamp value={row.finishedAt} />
                  {row.duration ? <div className="text-text-muted">{row.duration}</div> : null}
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

const listJobWorkflowsToolCard: ToolCardRenderer = {
  toolName: "list_job_workflows",
  collapsedSummary,
  renderExpanded
}

export default listJobWorkflowsToolCard

export const examples = [
  {
    id: "workflow_history",
    label: "Workflow history",
    input: { job_id: 42 },
    parsedResult: {
      job_id: 42,
      workflows: [
        {
          id: 91,
          trigger_kind: "initial",
          state: "succeeded",
          planned_execution: { project_label: "repo", target_label: "//:test", capabilities: { os: ["linux"] }, source: "explicit" },
          summary: "Implemented **responsive** workflow cards with linked references.",
          step_count: 4,
          run_count: 4,
          created_at: "2026-10-19T10:00:00Z",
          started_at: "2026-10-19T10:01:00Z",
          finished_at: "2026-10-19T10:08:00Z"
        }
      ]
    }
  },
  { id: "no_workflows", label: "No workflows", input: { job_id: 42 }, parsedResult: { job_id: 42, workflows: [] } },
  { id: "error", label: "Error", input: { job_id: 42 }, resultBody: "Job not found", resultError: true }
]

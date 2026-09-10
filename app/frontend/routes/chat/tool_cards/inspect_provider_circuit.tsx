import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { JobRefLink, Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for inspect_provider_circuit (the tool-card work).
// Renders the circuit decision (provider/model/scope, state, evidence age),
// the failed Runs and availability evidence backing that decision, and the
// consumers currently blocked on it (queued Workflows, delayed auto-retries)
// -- the recovery-action state an operator needs before manually clearing
// or waking the circuit.
type Decision = {
  provider: string
  open: boolean
  reason: string | null
  retryAfter: string | null
  failureCount: number | null
  jobCount: number | null
  model: string | null
  usageLimit: boolean
}

type RunRow = {
  key: string
  id: string
  jobId: string | null
  stepKind: string | null
  agentOutcome: string | null
  finishedAt: string | null
  classification: string | null
  usageLimitCandidate: boolean
  retryableCandidate: boolean
}

type EvidenceRow = { key: string; status: string | null; source: string | null; observedAt: string | null; model: string | null; httpStatus: number | null }

type QueuedWorkflowRow = { key: string; workflowId: string | null; jobId: string | null; startBlockedReason: string | null }

type DelayedRetryRow = { key: string; jobId: string | null; retryKind: string | null; scheduledAt: string | null }

type ProviderCircuitCard = {
  decision: Decision
  runs: RunRow[]
  evidence: EvidenceRow[]
  queuedWorkflows: QueuedWorkflowRow[]
  delayedRetries: DelayedRetryRow[]
}

function parseDecision(value: unknown): Decision | null {
  if (!isPlainObject(value)) return null
  const provider = displayValue(value.provider)
  if (!provider) return null

  return {
    provider,
    open: value.open === true,
    reason: displayValue(value.reason),
    retryAfter: displayValue(value.retry_after),
    failureCount: numberValue(value.failure_count),
    jobCount: numberValue(value.job_count),
    model: displayValue(value.model),
    usageLimit: value.usage_limit === true
  }
}

function parseRunRow(value: unknown, index: number): RunRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  const classification = isPlainObject(value.classification) ? displayValue(value.classification.classification) : null

  return {
    key: `${id}-${index}`,
    id,
    jobId: displayValue(value.job_id),
    stepKind: displayValue(value.step_kind),
    agentOutcome: displayValue(value.agent_outcome),
    finishedAt: displayValue(value.finished_at),
    classification,
    usageLimitCandidate: value.circuit_usage_limit_candidate === true,
    retryableCandidate: value.circuit_retryable_candidate === true
  }
}

function parseEvidenceRow(value: unknown, index: number): EvidenceRow | null {
  if (!isPlainObject(value)) return null

  return {
    key: `${index}`,
    status: displayValue(value.status),
    source: displayValue(value.source),
    observedAt: displayValue(value.observed_at),
    model: displayValue(value.model),
    httpStatus: numberValue(value.http_status)
  }
}

function parseQueuedWorkflow(value: unknown, index: number): QueuedWorkflowRow | null {
  if (!isPlainObject(value)) return null

  return {
    key: `${displayValue(value.workflow_id) ?? index}`,
    workflowId: displayValue(value.workflow_id),
    jobId: displayValue(value.job_id),
    startBlockedReason: displayValue(value.start_blocked_reason)
  }
}

function parseDelayedRetry(value: unknown, index: number): DelayedRetryRow | null {
  if (!isPlainObject(value)) return null

  return {
    key: `${displayValue(value.auto_retry_attempt_id) ?? index}`,
    jobId: displayValue(value.job_id),
    retryKind: displayValue(value.retry_kind),
    scheduledAt: displayValue(value.scheduled_at)
  }
}

function parseProviderCircuit(context: ToolCardContext): ProviderCircuitCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const decision = parseDecision(isPlainObject(parsed.decision) ? parsed.decision : parsed)
  if (!decision || !Array.isArray(parsed.runs)) return null

  const consumers = isPlainObject(parsed.consumers) ? parsed.consumers : {}

  return {
    decision,
    runs: parsed.runs.flatMap((run, index) => { const row = parseRunRow(run, index); return row ? [row] : [] }),
    evidence: Array.isArray(parsed.evidence_records) ? parsed.evidence_records.flatMap((record, index) => { const row = parseEvidenceRow(record, index); return row ? [row] : [] }) : [],
    queuedWorkflows: Array.isArray(consumers.queued_workflows_without_runs) ? consumers.queued_workflows_without_runs.flatMap((workflow, index) => { const row = parseQueuedWorkflow(workflow, index); return row ? [row] : [] }) : [],
    delayedRetries: Array.isArray(consumers.delayed_auto_retries) ? consumers.delayed_auto_retries.flatMap((retry, index) => { const row = parseDelayedRetry(retry, index); return row ? [row] : [] }) : []
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseProviderCircuit(context)
  if (!card) return null

  if (!card.decision.open) return `${card.decision.provider}: closed`
  const blocked = card.queuedWorkflows.length + card.delayedRetries.length
  return `${card.decision.provider}: open${card.decision.reason ? ` (${card.decision.reason})` : ""}${blocked > 0 ? `, ${blocked} blocked` : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseProviderCircuit(context)
  if (!card) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{card.decision.provider}</span>
        <StatePill state={card.decision.open ? "open" : "closed"} tone={card.decision.open ? "failure" : "success"} />
        {card.decision.model ? <Badge>{card.decision.model}</Badge> : null}
        {card.decision.usageLimit ? <Badge>usage limit</Badge> : null}
      </div>
      {card.decision.reason ? <div className="text-gray-700 dark:text-gray-300">{card.decision.reason}</div> : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Failure count" value={String(card.decision.failureCount ?? "—")} />
        <Row label="Job count" value={String(card.decision.jobCount ?? "—")} />
        {card.decision.retryAfter ? <Row label="Retry after" value={card.decision.retryAfter} /> : null}
      </dl>
      <div>
        <SectionLabel>Failed Runs ({card.runs.length})</SectionLabel>
        {card.runs.length === 0 ? (
          <EmptyState>No failed Runs in the evidence window.</EmptyState>
        ) : (
          <Table>
            <THead columns={["Run", "Job", "Step", "Outcome", "Classification", "Finished", "Candidate"]} />
            <TBody>
              {card.runs.map((run) => (
                <tr key={run.key}>
                  <Td mono>RUN-{run.id}</Td>
                  <Td><JobRefLink jobId={run.jobId} /></Td>
                  <Td>{run.stepKind || "—"}</Td>
                  <Td>{run.agentOutcome || "—"}</Td>
                  <Td>{run.classification || "—"}</Td>
                  <Td mono>{run.finishedAt || "—"}</Td>
                  <Td>
                    {run.usageLimitCandidate ? <Badge>usage limit</Badge> : null}
                    {run.retryableCandidate ? <Badge>retryable</Badge> : null}
                    {!run.usageLimitCandidate && !run.retryableCandidate ? "—" : null}
                  </Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
      </div>
      {card.evidence.length > 0 ? (
        <Disclosure label={`Availability evidence (${card.evidence.length})`}>
          <Table>
            <THead columns={["Status", "Source", "Observed", "Model", "HTTP"]} />
            <TBody>
              {card.evidence.map((record) => (
                <tr key={record.key}>
                  <Td>{record.status ? <StatePill state={record.status} /> : "—"}</Td>
                  <Td>{record.source || "—"}</Td>
                  <Td mono>{record.observedAt || "—"}</Td>
                  <Td>{record.model || "—"}</Td>
                  <Td mono>{record.httpStatus ?? "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        </Disclosure>
      ) : null}
      {card.queuedWorkflows.length > 0 || card.delayedRetries.length > 0 ? (
        <div>
          <SectionLabel>Blocked consumers</SectionLabel>
          {card.queuedWorkflows.length > 0 ? (
            <div className="mt-1">
              <div className="text-2xs text-gray-500 dark:text-gray-400">Queued workflows without Runs ({card.queuedWorkflows.length})</div>
              <ul className="mt-1 space-y-1">
                {card.queuedWorkflows.map((workflow) => (
                  <li className="flex flex-wrap items-center gap-2" key={workflow.key}>
                    <span className="font-mono text-gray-700 dark:text-gray-300">{workflow.workflowId ? `WF-${workflow.workflowId}` : "—"}</span>
                    <JobRefLink jobId={workflow.jobId} />
                    {workflow.startBlockedReason ? <Badge>{workflow.startBlockedReason.replace(/_/g, " ")}</Badge> : null}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {card.delayedRetries.length > 0 ? (
            <div className="mt-2">
              <div className="text-2xs text-gray-500 dark:text-gray-400">Delayed auto-retries ({card.delayedRetries.length})</div>
              <ul className="mt-1 space-y-1">
                {card.delayedRetries.map((retry) => (
                  <li className="flex flex-wrap items-center gap-2" key={retry.key}>
                    <JobRefLink jobId={retry.jobId} />
                    {retry.retryKind ? <Badge>{retry.retryKind}</Badge> : null}
                    <span className="font-mono text-gray-500 dark:text-gray-400">{retry.scheduledAt || "—"}</span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      ) : null}
    </CardShell>
  )
}

const inspectProviderCircuitToolCard: ToolCardRenderer = {
  toolName: "inspect_provider_circuit",
  collapsedSummary,
  renderExpanded
}

export default inspectProviderCircuitToolCard

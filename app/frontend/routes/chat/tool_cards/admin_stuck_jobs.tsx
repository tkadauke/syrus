import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { useT } from "../../../hooks/useT"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, StatePill } from "../toolCardUi"
import { MarkdownPreview } from "../toolCardMarkdown"

type StuckItemRow = {
  key: string
  id: string | null
  title: string | null
  state: string | null
  kind: string
  severity: string | null
  reconcilerSeverity: string | null
  attentionState: string | null
  detail: string | null
  ageLabel: string | null
  ageSeconds: string | null
  runId: string | null
  runState: string | null
  workflowId: string | null
  workflowSlug: string | null
  workflowPath: string | null
  workflowState: string | null
  workflowTriggerKind: string | null
  jobId: string | null
  jobState: string | null
  jobPath: string | null
  stepKind: string | null
  lastHeartbeatAt: string | null
  hasTranscript: boolean | null
  issue: unknown
  repairPlan: Record<string, unknown> | null
  repairExecution: Record<string, unknown> | null
}

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null
}

function serializedValue(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === "string") return value || null
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  try {
    return JSON.stringify(value)
  } catch {
    return null
  }
}

function parseRow(value: unknown, index: number): StuckItemRow | null {
  if (!isPlainObject(value)) return null
  const kind = displayValue(value.kind)
  if (!kind) return null
  const jobId = displayValue(value.job_id)
  const workflowId = displayValue(value.workflow_id)
  const runId = displayValue(value.run_id)
  return {
    key: `${jobId ?? "job"}-${workflowId ?? "workflow"}-${runId ?? "run"}-${kind}-${index}`,
    id: displayValue(value.id),
    title: displayValue(value.title),
    state: displayValue(value.state),
    kind,
    severity: displayValue(value.severity),
    reconcilerSeverity: displayValue(value.reconciler_severity),
    attentionState: displayValue(value.attention_state),
    detail: displayValue(value.detail),
    ageLabel: displayValue(value.age_label),
    ageSeconds: displayValue(value.age_seconds),
    runId,
    runState: displayValue(value.run_state),
    workflowId,
    workflowSlug: displayValue(value.workflow_slug),
    workflowPath: displayValue(value.workflow_path),
    workflowState: displayValue(value.workflow_state),
    workflowTriggerKind: displayValue(value.workflow_trigger_kind),
    jobId,
    jobState: displayValue(value.job_state),
    jobPath: displayValue(value.job_path),
    stepKind: displayValue(value.step_kind),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    hasTranscript: booleanValue(value.has_transcript),
    issue: value.issue,
    repairPlan: isPlainObject(value.repair_plan) ? value.repair_plan : null,
    repairExecution: isPlainObject(value.repair_execution) ? value.repair_execution : null
  }
}

function stuckRows(context: ToolCardContext): StuckItemRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.items)) return null
  return parsed.items.flatMap((item, index) => {
    const row = parseRow(item, index)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("chat:admin_stuck_jobs.error_summary")
  const rows = stuckRows(context)
  return rows ? i18n.t("chat:admin_stuck_jobs.item_count", { count: rows.length }) : null
}

function LabeledValue({ label, value, mono = false }: { label: string; value: unknown; mono?: boolean }) {
  const displayed = serializedValue(value)
  return (
    <div className="min-w-0">
      <span className="mr-1 text-2xs font-medium uppercase tracking-wide text-text-muted">{label}</span>
      <span className={`${mono ? "font-mono" : ""} break-words [overflow-wrap:anywhere] text-text-primary`}>{displayed ?? "—"}</span>
    </div>
  )
}

function RepairPlan({ plan, execution }: { plan: Record<string, unknown> | null; execution: Record<string, unknown> | null }) {
  const { t } = useT("chat")
  if (!plan && !execution) return <>—</>
  const steps = Array.isArray(plan?.execution_steps) ? plan.execution_steps : []
  return (
    <div className="min-w-0 space-y-1.5 whitespace-normal">
      {plan ? (
        <>
          <LabeledValue label={t("admin_stuck_jobs.action")} value={displayValue(plan.action)?.replace(/_/g, " ")} />
          <LabeledValue label={t("admin_stuck_jobs.issue_kind")} value={plan.issue_kind} />
          <LabeledValue label={t("admin_stuck_jobs.automatic")} value={plan.auto_executable} />
          <LabeledValue
            label={t("admin_stuck_jobs.target")}
            value={[displayValue(plan.target_type), displayValue(plan.target_id)].filter(Boolean).join(" ")}
            mono
          />
          <LabeledValue label={t("admin_stuck_jobs.affected")} value={plan.affected_ids} mono />
          <LabeledValue label={t("admin_stuck_jobs.preconditions")} value={plan.preconditions} mono />
          <LabeledValue label={t("admin_stuck_jobs.retry_after")} value={plan.retry_after} mono />
          <LabeledValue label={t("admin_stuck_jobs.check_after")} value={plan.check_after} mono />
          {displayValue(plan.reason) ? (
            <MarkdownPreview maxLines={3} text={String(plan.reason)} title={t("admin_stuck_jobs.reason")} />
          ) : (
            <LabeledValue label={t("admin_stuck_jobs.reason")} value={null} />
          )}
          <div>
            <span className="text-2xs font-medium uppercase tracking-wide text-text-muted">{t("admin_stuck_jobs.steps")}</span>
            {steps.length ? (
              <ol className="ml-4 list-decimal space-y-0.5">
                {steps.map((step, index) => (
                  <li className="break-words" key={`${index}-${serializedValue(step)}`}>
                    {serializedValue(step)}
                  </li>
                ))}
              </ol>
            ) : (
              <div>—</div>
            )}
          </div>
        </>
      ) : null}
      {execution ? (
        <div className="border-t border-border pt-1.5">
          <LabeledValue label={t("admin_stuck_jobs.execution_action")} value={execution.action} />
          <LabeledValue
            label={t("admin_stuck_jobs.execution_target")}
            value={[displayValue(execution.target_type), displayValue(execution.target_id)].filter(Boolean).join(" ")}
            mono
          />
          <LabeledValue label={t("admin_stuck_jobs.execution_status")} value={execution.status} />
          <LabeledValue label={t("admin_stuck_jobs.execution_message")} value={execution.message} />
        </div>
      ) : null}
    </div>
  )
}

function StuckJobsCard({ context }: { context: ToolCardContext }) {
  const { t } = useT("chat")
  if (context.resultError) return <EmptyState>{t("admin_stuck_jobs.error")}</EmptyState>
  const rows = stuckRows(context)
  if (!rows) return null
  if (rows.length === 0) return <EmptyState>{t("admin_stuck_jobs.empty")}</EmptyState>
  return (
    <CardShell>
      <Table responsive>
        <THead columns={["job", "workflow", "run", "severity", "diagnostic", "timing", "repair_plan"].map((key) => t(`admin_stuck_jobs.${key}`))} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td primary wrap>
                <div className="space-y-1">
                  <EntityReference
                    href={row.jobPath}
                    id={row.jobId}
                    kind="job"
                    label={row.jobId ? `JOB-${row.jobId}${row.title ? ` — ${row.title}` : ""}` : row.title}
                  />
                  <LabeledValue label={t("admin_stuck_jobs.record_id")} value={row.id} mono />
                  <LabeledValue label={t("admin_stuck_jobs.state")} value={row.state} />
                  <LabeledValue label={t("admin_stuck_jobs.job_state")} value={row.jobState} />
                </div>
              </Td>
              <Td wrap>
                <div className="space-y-1">
                  <EntityReference href={row.workflowPath} id={row.workflowId} jobId={row.jobId} kind="workflow" />
                  <LabeledValue label={t("admin_stuck_jobs.slug")} value={row.workflowSlug} mono />
                  <LabeledValue label={t("admin_stuck_jobs.state")} value={row.workflowState} />
                  <LabeledValue label={t("admin_stuck_jobs.trigger")} value={row.workflowTriggerKind} />
                </div>
              </Td>
              <Td wrap>
                <div className="space-y-1">
                  <EntityReference id={row.runId} jobId={row.jobId} kind="run" workflowId={row.workflowId} />
                  <LabeledValue label={t("admin_stuck_jobs.state")} value={row.runState} />
                  <LabeledValue label={t("admin_stuck_jobs.step")} value={row.stepKind} />
                  <LabeledValue label={t("admin_stuck_jobs.transcript")} value={row.hasTranscript} />
                </div>
              </Td>
              <Td wrap>
                <div className="space-y-1">
                  {row.severity ? <StatePill state={row.severity} /> : "—"}
                  <LabeledValue label={t("admin_stuck_jobs.reconciler")} value={row.reconcilerSeverity} />
                  <div>{row.attentionState ? <StatePill state={row.attentionState} /> : "—"}</div>
                </div>
              </Td>
              <Td wrap>
                <div className="min-w-0 space-y-1.5">
                  <Badge>{row.kind.replace(/_/g, " ")}</Badge>
                  {row.detail ? (
                    <MarkdownPreview maxLines={4} text={row.detail} title={t("admin_stuck_jobs.detail")} />
                  ) : (
                    <LabeledValue label={t("admin_stuck_jobs.detail")} value={null} />
                  )}
                  <LabeledValue label={t("admin_stuck_jobs.issue")} value={row.issue} mono />
                </div>
              </Td>
              <Td wrap>
                <div className="space-y-1">
                  <LabeledValue label={t("admin_stuck_jobs.age")} value={row.ageLabel} />
                  <LabeledValue label={t("admin_stuck_jobs.seconds")} value={row.ageSeconds} mono />
                  <LabeledValue label={t("admin_stuck_jobs.heartbeat")} value={row.lastHeartbeatAt} mono />
                </div>
              </Td>
              <Td wrap>
                <RepairPlan execution={row.repairExecution} plan={row.repairPlan} />
              </Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (!context.resultError && !stuckRows(context)) return null
  return <StuckJobsCard context={context} />
}

const adminStuckJobsToolCard: ToolCardRenderer = { toolName: "admin_stuck_jobs", collapsedSummary, renderExpanded }
export default adminStuckJobsToolCard

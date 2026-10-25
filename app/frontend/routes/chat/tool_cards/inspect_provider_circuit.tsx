import i18n from "../../../i18n"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { redactToolCardText, redactToolCardValue } from "@app/toolCardSecurity"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, EntityReference, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { Table, TBody, Td, THead } from "../adminToolCard"

type Obj = Record<string, unknown>
type Item = { key: string; value: Obj }
type Card = { decision: Obj; provider: string; runs: Item[]; evidence: Item[]; workflows: Item[]; retries: Item[] }

const text = (value: unknown) => {
  const displayed = displayValue(value)
  return displayed ? redactToolCardText(displayed) : null
}
const json = (value: unknown) => (value == null ? null : JSON.stringify(redactToolCardValue(value), null, 2))
const list = (value: unknown, prefix: string): Item[] =>
  Array.isArray(value)
    ? value
        .filter(isPlainObject)
        .map((item, index) => ({ key: `${displayValue(item.id) ?? displayValue(item[`${prefix}_id`]) ?? prefix}-${index}`, value: item }))
    : []

function parse(context: ToolCardContext): Card | null {
  if (!isPlainObject(context.parsedResult) || !Array.isArray(context.parsedResult.runs)) return null
  const result = context.parsedResult
  const decision = isPlainObject(result.decision) ? result.decision : result
  const provider = displayValue(decision.provider)
  if (!provider) return null
  const consumers = isPlainObject(result.consumers) ? result.consumers : {}
  return {
    decision,
    provider,
    runs: list(result.runs, "run"),
    evidence: list(result.evidence_records, "evidence"),
    workflows: list(consumers.queued_workflows_without_runs, "workflow"),
    retries: list(consumers.delayed_auto_retries, "auto_retry_attempt")
  }
}

function Preview({ markdown = false, title, value }: { markdown?: boolean; title: string; value: unknown }) {
  const safe = typeof value === "string" ? text(value) : json(value)
  if (!safe) return <>—</>
  return markdown ? <MarkdownPreview maxLines={3} text={safe} title={title} /> : <TextPreview maxLines={3} text={safe} title={title} />
}

function Ref({
  id,
  kind,
  jobId,
  workflowId,
  label,
  slug
}: {
  id: unknown
  kind: "artifact" | "chat" | "job" | "run" | "workflow"
  jobId?: unknown
  workflowId?: unknown
  label?: string
  slug?: string
}) {
  const value = displayValue(id)
  return value ? (
    <EntityReference id={value} jobId={displayValue(jobId)} kind={kind} label={label} slug={slug} workflowId={displayValue(workflowId)} wrap="nowrap" />
  ) : (
    <>—</>
  )
}

function Classification({ value }: { value: unknown }) {
  if (!isPlainObject(value)) return <>—</>
  const id = displayValue(value.id)
  return (
    <div className="min-w-0 space-y-1">
      <div className="flex flex-wrap items-center gap-1">
        <Ref id={id} kind="artifact" label={id ? `Classification ${id}` : undefined} slug={id ?? undefined} />
        {displayValue(value.classification) ? <StatePill state={displayValue(value.classification)!} /> : null}
        {value.retryable === true ? <Badge>retryable</Badge> : value.retryable === false ? <Badge>{i18n.t("chat:ops_not_retryable_45d0e0")}</Badge> : null}
        {numberValue(value.confidence) != null ? <Badge>{numberValue(value.confidence)} confidence</Badge> : null}
      </div>
      <Preview markdown title={i18n.t("chat:ops_reason_f219cc")} value={value.reason} />
      <Preview markdown title={i18n.t("chat:ops_diagnostic_summary_52067a")} value={value.diagnostic_summary} />
      <Preview title={i18n.t("chat:ops_classifier_inputs_f5b4df")} value={value.classifier_inputs} />
      <div className="font-mono text-text-muted">{displayValue(value.classified_at) ?? "—"}</div>
      {value.repair != null ? <Preview title={i18n.t("chat:ops_repair_5f60b1")} value={value.repair} /> : null}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const card = parse(context)
  if (!card) return null
  if (card.decision.open !== true) return `${card.provider}: closed`
  const blocked = card.workflows.length + card.retries.length
  const reason = text(card.decision.reason)
  return `${card.provider}: open${reason ? ` (${reason})` : ""}${blocked ? `, ${blocked} blocked` : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parse(context)
  if (!card) return null
  const d = card.decision
  const inputProvider = displayValue(context.input?.provider)
  const inputUserId = displayValue(context.input?.user_id)
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-text-primary">{card.provider}</span>
        <StatePill state={d.open === true ? "open" : "closed"} tone={d.open === true ? "failure" : "success"} />
        {displayValue(d.model) ? <Badge>{displayValue(d.model)}</Badge> : null}
        {d.usage_limit === true ? <Badge>{i18n.t("chat:ops_usage_limit_2564f4")}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={i18n.t("chat:ops_input_provider_f9980e")} value={inputProvider ?? "—"} />
        <Row label={i18n.t("chat:ops_input_user_id_6318a2")} value={inputUserId ?? "—"} />
        <Row label={i18n.t("chat:ops_failure_count_1ac156")} value={String(numberValue(d.failure_count) ?? "—")} />
        <Row label={i18n.t("chat:ops_job_count_dc7bb1")} value={String(numberValue(d.job_count) ?? "—")} />
        <Row label={i18n.t("chat:ops_retry_after_75342d")} value={displayValue(d.retry_after) ?? "—"} />
      </dl>
      {d.reason ? <Preview markdown title={i18n.t("chat:ops_decision_reason_6b9c2c")} value={d.reason} /> : null}
      <div className="grid gap-2 sm:grid-cols-2">
        <Preview title={i18n.t("chat:ops_signature_2f32be")} value={d.signature} />
        <Preview title={i18n.t("chat:ops_decision_evidence_120846")} value={d.evidence} />
      </div>

      <div>
        <SectionLabel>{i18n.t("chat:failed_run_count", { count: card.runs.length })}</SectionLabel>
        {card.runs.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_failed_runs_in_the_evidence_window_c909ea")}</EmptyState>
        ) : (
          <Table responsive>
            <THead
              columns={[
                "Run",
                "Job",
                "Workflow / step",
                "Provider / model",
                "Outcome / retry",
                i18n.t("chat:ops_diagnostic_852a16"),
                i18n.t("chat:ops_classification_94c2a3"),
                i18n.t("chat:ops_finished_355bcc"),
                i18n.t("chat:ops_candidates_b5bf80")
              ]}
            />
            <TBody>
              {card.runs.map(({ key, value: r }) => {
                const diagnostic = isPlainObject(r.diagnostic) ? r.diagnostic : null
                const jobId = displayValue(r.job_id)
                const workflowId = displayValue(r.workflow_id)
                return (
                  <tr key={key}>
                    <Td>
                      <Ref id={r.id} jobId={jobId} kind="run" workflowId={workflowId} />
                    </Td>
                    <Td>
                      <Ref id={jobId} kind="job" />
                      <div>{displayValue(r.job_slug) ?? "—"}</div>
                    </Td>
                    <Td>
                      <Ref id={workflowId} jobId={jobId} kind="workflow" />
                      <div>
                        {displayValue(r.step_kind) ?? "—"} {displayValue(r.step_id) ? `(STEP-${displayValue(r.step_id)})` : ""}
                      </div>
                      <div>{displayValue(r.trigger_kind) ?? "—"}</div>
                    </Td>
                    <Td>
                      <div>{displayValue(r.agent_provider) ?? "—"}</div>
                      <div>{displayValue(r.extracted_model) ?? "—"}</div>
                    </Td>
                    <Td>
                      <div>{displayValue(r.agent_outcome) ?? "—"}</div>
                      <div className="font-mono">{displayValue(r.retry_after) ?? "—"}</div>
                    </Td>
                    <Td wrap>
                      <Ref
                        id={diagnostic?.id}
                        kind="artifact"
                        label={displayValue(diagnostic?.id) ? `Diagnostic ${displayValue(diagnostic?.id)}` : undefined}
                        slug={displayValue(diagnostic?.id) ?? undefined}
                      />
                      <div>{text(diagnostic?.error_class) ?? "—"}</div>
                      <Preview title={i18n.t("chat:ops_error_message_34d6de")} value={diagnostic?.error_message} />
                    </Td>
                    <Td wrap>
                      <Classification value={r.classification} />
                    </Td>
                    <Td mono>{displayValue(r.finished_at) ?? "—"}</Td>
                    <Td>
                      <div className="flex flex-col items-start gap-1">
                        {r.circuit_usage_limit_candidate === true ? <Badge>{i18n.t("chat:ops_usage_limit_2564f4")}</Badge> : null}
                        {r.circuit_retryable_candidate === true ? <Badge>retryable</Badge> : null}
                        {r.circuit_usage_limit_candidate !== true && r.circuit_retryable_candidate !== true ? "—" : null}
                      </div>
                    </Td>
                  </tr>
                )
              })}
            </TBody>
          </Table>
        )}
      </div>

      <Disclosure label={i18n.t("chat:availability_evidence_count", { count: card.evidence.length })}>
        {card.evidence.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_availability_evidence_in_the_evidence_window_753eec")}</EmptyState>
        ) : (
          <Table responsive>
            <THead
              columns={[
                i18n.t("chat:ops_evidence_7ea014"),
                "Status / source",
                i18n.t("chat:ops_scope_4651a3"),
                i18n.t("chat:ops_references_5d20d0"),
                i18n.t("chat:ops_observed_2e159b"),
                "HTTP",
                i18n.t("chat:ops_details_dc3dec"),
                i18n.t("chat:ops_repair_5f60b1")
              ]}
            />
            <TBody>
              {card.evidence.map(({ key, value: e }) => {
                const id = displayValue(e.id)
                return (
                  <tr key={key}>
                    <Td>
                      <Ref id={id} kind="artifact" label={id ? `Evidence ${id}` : undefined} slug={id ?? undefined} />
                    </Td>
                    <Td>
                      <div>{displayValue(e.status) ? <StatePill state={displayValue(e.status)!} /> : "—"}</div>
                      <div>{displayValue(e.source) ?? "—"}</div>
                    </Td>
                    <Td>
                      <div>{displayValue(e.provider) ?? "—"}</div>
                      <div>{displayValue(e.account_id) ?? "—"}</div>
                      <div>{displayValue(e.model) ?? "—"}</div>
                    </Td>
                    <Td>
                      <Ref id={e.run_id} kind="run" />
                      <div>
                        <Ref id={e.chat_session_id} kind="chat" />
                      </div>
                      <div>{displayValue(e.chat_message_id) ? `Message ${displayValue(e.chat_message_id)}` : "—"}</div>
                    </Td>
                    <Td mono>{displayValue(e.observed_at) ?? "—"}</Td>
                    <Td mono>{numberValue(e.http_status) ?? "—"}</Td>
                    <Td wrap>
                      <Preview title={i18n.t("chat:ops_details_dc3dec")} value={e.details} />
                    </Td>
                    <Td wrap>
                      <Preview title={i18n.t("chat:ops_repair_5f60b1")} value={e.repair} />
                    </Td>
                  </tr>
                )
              })}
            </TBody>
          </Table>
        )}
      </Disclosure>

      <div>
        <SectionLabel>{i18n.t("chat:ops_blocked_consumers_110415")}</SectionLabel>
        {card.workflows.length === 0 && card.retries.length === 0 ? <EmptyState>{i18n.t("chat:ops_no_blocked_consumers_c6c798")}</EmptyState> : null}
        {card.workflows.length ? (
          <Table responsive>
            <THead
              columns={[
                i18n.t("chat:ops_workflow_d7a484"),
                "Job",
                i18n.t("chat:ops_trigger_d3f06a"),
                i18n.t("chat:ops_blocked_reason_6a04fd"),
                i18n.t("chat:ops_details_dc3dec"),
                i18n.t("chat:ops_next_check_75d4a7")
              ]}
            />
            <TBody>
              {card.workflows.map(({ key, value: w }) => {
                const jobId = displayValue(w.job_id)
                return (
                  <tr key={key}>
                    <Td>
                      <Ref id={w.workflow_id} jobId={jobId} kind="workflow" />
                    </Td>
                    <Td>
                      <Ref id={jobId} kind="job" />
                      <div>{displayValue(w.job_slug) ?? "—"}</div>
                    </Td>
                    <Td>{displayValue(w.trigger_kind) ?? "—"}</Td>
                    <Td>{displayValue(w.start_blocked_reason) ?? "—"}</Td>
                    <Td wrap>
                      <Preview title={i18n.t("chat:ops_start_block_details_0fd535")} value={w.start_blocked_details} />
                    </Td>
                    <Td mono>{displayValue(w.next_check_at) ?? "—"}</Td>
                  </tr>
                )
              })}
            </TBody>
          </Table>
        ) : null}
        {card.retries.length ? (
          <Table responsive>
            <THead
              columns={[
                i18n.t("chat:ops_retry_9f5cd8"),
                "Job",
                i18n.t("chat:ops_workflow_d7a484"),
                "Run",
                i18n.t("chat:ops_kind_e00ac2"),
                i18n.t("chat:ops_scheduled_1cd1bd"),
                i18n.t("chat:ops_classification_94c2a3")
              ]}
            />
            <TBody>
              {card.retries.map(({ key, value: r }) => {
                const jobId = displayValue(r.job_id)
                const workflowId = displayValue(r.workflow_id)
                return (
                  <tr key={key}>
                    <Td mono>{displayValue(r.auto_retry_attempt_id) ?? "—"}</Td>
                    <Td>
                      <Ref id={jobId} kind="job" />
                      <div>{displayValue(r.job_slug) ?? "—"}</div>
                    </Td>
                    <Td>
                      <Ref id={workflowId} jobId={jobId} kind="workflow" />
                    </Td>
                    <Td>
                      <Ref id={r.run_id} jobId={jobId} kind="run" workflowId={workflowId} />
                    </Td>
                    <Td>{displayValue(r.retry_kind) ?? "—"}</Td>
                    <Td mono>{displayValue(r.scheduled_at) ?? "—"}</Td>
                    <Td>{displayValue(r.failure_classification) ?? "—"}</Td>
                  </tr>
                )
              })}
            </TBody>
          </Table>
        ) : null}
      </div>
    </CardShell>
  )
}

const inspectProviderCircuitToolCard: ToolCardRenderer = { toolName: "inspect_provider_circuit", collapsedSummary, renderExpanded }
export default inspectProviderCircuitToolCard

import { CopyableSlug } from "@app/components/CopyableSlug"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EntityReference, Row, StatePill } from "../toolCardUi"

type InvocationContextSuccess = {
  ok: true
  surface: string
  role: string
  runId: string | null
  jobId: string | null
  chatSessionId: string | null
  currentMessageId: string | null
  tier: string
  provider: string
}

type InvocationContextFailure = {
  ok: false
  error: string
  message: string
}

type InvocationContext = InvocationContextSuccess | InvocationContextFailure

function parseInvocationContext(context: ToolCardContext): InvocationContext | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.ok !== "boolean") return null

  if (!parsed.ok) {
    const error = displayValue(parsed.error)
    const message = displayValue(parsed.message)
    return error && message ? { ok: false, error, message } : null
  }

  const surface = displayValue(parsed.surface)
  const role = displayValue(parsed.role)
  const tier = displayValue(parsed.tier)
  const provider = displayValue(parsed.provider)
  if (!surface || !role || !tier || !provider) return null

  return {
    ok: true,
    surface,
    role,
    runId: displayValue(parsed.run_id),
    jobId: displayValue(parsed.job_id),
    chatSessionId: displayValue(parsed.chat_session_id),
    currentMessageId: displayValue(parsed.current_message_id),
    tier,
    provider
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseInvocationContext(context)
  if (!card) return null
  if (!card.ok) return `invocation context denied: ${card.error}`

  const identity = card.chatSessionId ?? card.runId ?? card.jobId
  return `invocation context: ${card.surface}${identity ? ` ${identity}` : ""}`
}

function CopyableValue({ value }: { value: string }) {
  return <CopyableSlug className="text-xs" slug={value} />
}

function renderExpanded(context: ToolCardContext) {
  const card = parseInvocationContext(context)
  if (!card) return null

  if (!card.ok) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="denied" tone="failure" />
          <span className="font-mono text-xs font-semibold text-danger-text">{card.error}</span>
        </div>
        <div className="break-words rounded border border-danger-border bg-danger-surface px-2 py-1 text-sm text-danger-text">{card.message}</div>
      </CardShell>
    )
  }

  return (
    <CardShell>
      <StatePill state="ok" tone="success" />
      <dl className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        <Row label="Surface" value={card.surface} />
        <Row label="Role" value={card.role} />
        <Row label="Tier" value={card.tier} />
        <Row label="Provider" value={card.provider} />
        {card.jobId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">Job</dt>
            <dd>
              <EntityReference id={card.jobId} kind="job" />
            </dd>
          </div>
        ) : null}
        {card.chatSessionId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">Chat session</dt>
            <dd>
              <EntityReference id={card.chatSessionId} kind="chat" />
            </dd>
          </div>
        ) : null}
        {card.runId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">Run ID</dt>
            <dd>
              <CopyableValue value={card.runId} />
            </dd>
          </div>
        ) : null}
        {card.currentMessageId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">Current message ID</dt>
            <dd>
              <CopyableValue value={card.currentMessageId} />
            </dd>
          </div>
        ) : null}
      </dl>
    </CardShell>
  )
}

const daemonInvocationContextToolCard: ToolCardRenderer = {
  toolName: "daemon_invocation_context",
  collapsedSummary,
  renderExpanded
}

export default daemonInvocationContextToolCard

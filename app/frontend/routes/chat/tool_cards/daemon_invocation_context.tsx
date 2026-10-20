import { CopyableSlug } from "@app/components/CopyableSlug"
import { useT } from "@app/hooks/useT"
import i18n from "@app/i18n"
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
  if (!card.ok) return i18n.t("chat:daemon_invocation_context.summary_denied", { error: card.error })

  const identity = card.chatSessionId ?? card.runId ?? card.jobId
  return i18n.t("chat:daemon_invocation_context.summary", { surface: card.surface, identity: identity ? ` ${identity}` : "" })
}

function CopyableValue({ value }: { value: string }) {
  return <CopyableSlug className="text-xs" slug={value} />
}

function InvocationContextCard({ card }: { card: InvocationContext }) {
  const { t } = useT("chat")

  if (!card.ok) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={t("daemon_invocation_context.denied")} tone="failure" />
          <span className="font-mono text-xs font-semibold text-danger-text">{card.error}</span>
        </div>
        <div className="break-words rounded border border-danger-border bg-danger-surface px-2 py-1 text-sm text-danger-text">{card.message}</div>
      </CardShell>
    )
  }

  return (
    <CardShell>
      <StatePill state={t("daemon_invocation_context.ok")} tone="success" />
      <dl className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
        <Row label={t("daemon_invocation_context.surface")} value={card.surface} />
        <Row label={t("daemon_invocation_context.role")} value={card.role} />
        <Row label={t("daemon_invocation_context.tier")} value={card.tier} />
        <Row label={t("daemon_invocation_context.provider")} value={card.provider} />
        {card.jobId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("daemon_invocation_context.job")}</dt>
            <dd>
              <EntityReference id={card.jobId} kind="job" />
            </dd>
          </div>
        ) : null}
        {card.chatSessionId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("daemon_invocation_context.chat_session")}</dt>
            <dd>
              <EntityReference id={card.chatSessionId} kind="chat" />
            </dd>
          </div>
        ) : null}
        {card.runId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("daemon_invocation_context.run_id")}</dt>
            <dd>
              <CopyableValue value={card.runId} />
            </dd>
          </div>
        ) : null}
        {card.currentMessageId ? (
          <div className="min-w-0">
            <dt className="text-2xs font-semibold uppercase text-text-muted">{t("daemon_invocation_context.current_message_id")}</dt>
            <dd>
              <CopyableValue value={card.currentMessageId} />
            </dd>
          </div>
        ) : null}
      </dl>
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseInvocationContext(context)
  return card ? <InvocationContextCard card={card} /> : null
}

const daemonInvocationContextToolCard: ToolCardRenderer = {
  toolName: "daemon_invocation_context",
  collapsedSummary,
  renderExpanded
}

export default daemonInvocationContextToolCard

import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { displayValue, EmptyState, EntityReference, Row, SectionLabel } from "../toolCardUi"
import { ErrorCard, MalformedCard, OptionalReason, StatusCard, successOrError } from "../chatHelperToolCard"

type GoalResult = {
  goalId: string
  status: string
  previousStatus: string | null
  reason: string | null
  details: Record<string, unknown> | null
  chatSessionId: string | null
  chatTitle: string | null
  chatPath: string | null
}

function parseGoalResult(context: ToolCardContext) {
  return successOrError<GoalResult>(context, i18n.t("chat:tool_card_goal_blocked_failed"), (parsed) => {
    const goalId = displayValue(parsed.goal_id)
    const status = displayValue(parsed.status)
    if (!goalId || !status) return null
    return {
      goalId,
      status,
      previousStatus: displayValue(parsed.previous_status),
      reason: displayValue(parsed.reason),
      details: isPlainObject(parsed.details) ? parsed.details : null,
      chatSessionId: displayValue(parsed.chat_session_id),
      chatTitle: displayValue(parsed.chat_title),
      chatPath: displayValue(parsed.chat_path)
    }
  })
}

function requestIsPending(context: ToolCardContext) {
  return context.parsedResult == null && !context.resultBody.trim()
}

function inputReason(context: ToolCardContext) {
  return displayValue(context.input?.reason)
}

function inputDetails(context: ToolCardContext) {
  return isPlainObject(context.input?.details) ? context.input.details : null
}

function detailValue(value: unknown) {
  const displayed = displayValue(value)
  if (displayed) return displayed
  if (value == null) return "—"
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function Details({ details }: { details: Record<string, unknown> | null }) {
  if (!details || Object.keys(details).length === 0) return <EmptyState>{i18n.t("chat:tool_card_goal_blocked_no_details")}</EmptyState>

  return (
    <details className="min-w-0 rounded border border-border bg-surface px-2 py-1 sm:col-span-2">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted">{i18n.t("chat:tool_card_goal_blocked_details")}</summary>
      <dl className="mt-2 grid min-w-0 gap-2 sm:grid-cols-2">
        {Object.entries(details).map(([key, value]) => (
          <div className="min-w-0" key={key}>
            <SectionLabel>{key}</SectionLabel>
            <div className="break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]">{detailValue(value)}</div>
          </div>
        ))}
      </dl>
    </details>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  if (parsed.kind === "error") return i18n.t("chat:tool_card_goal_blocked_failed")
  if (parsed.kind === "malformed")
    return requestIsPending(context) ? i18n.t("chat:tool_card_goal_blocked_pending") : i18n.t("chat:tool_card_goal_blocked_unexpected")
  return i18n.t("chat:tool_card_goal_transition_summary", { goalId: parsed.data.goalId, status: parsed.data.status })
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseGoalResult(context)
  const title = i18n.t("chat:tool_card_goal_blocked_transition")
  if (parsed.kind === "error") return <ErrorCard title={title} message={parsed.message} />
  if (parsed.kind === "malformed") {
    if (requestIsPending(context)) {
      return (
        <StatusCard title={title} status="pending">
          <OptionalReason reason={inputReason(context)} />
          <Details details={inputDetails(context)} />
          <EmptyState>{i18n.t("chat:tool_card_goal_blocked_waiting")}</EmptyState>
        </StatusCard>
      )
    }
    return <MalformedCard title={title} />
  }

  const reason = parsed.data.reason || inputReason(context)
  const details = parsed.data.details || inputDetails(context)
  const previousStatus = parsed.data.previousStatus || i18n.t("chat:tool_card_unknown_status")

  return (
    <StatusCard title={title} status={parsed.data.status}>
      <dl className="grid gap-1 sm:grid-cols-2">
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:tool_card_goal")}</SectionLabel>
          {parsed.data.chatSessionId ? (
            <EntityReference
              href={parsed.data.chatPath}
              id={parsed.data.chatSessionId}
              kind="chat"
              label={i18n.t("chat:tool_card_goal_chat_label", {
                goalId: parsed.data.goalId,
                chatTitle: parsed.data.chatTitle ? ` · ${parsed.data.chatTitle}` : ""
              })}
            />
          ) : (
            <div className="break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]">#{parsed.data.goalId}</div>
          )}
        </div>
        <Row label={i18n.t("chat:tool_card_transition")} value={`${previousStatus} -> ${parsed.data.status}`} />
        <OptionalReason reason={reason} title={i18n.t("chat:tool_card_goal_blocked_reason")} />
        <Details details={details} />
      </dl>
    </StatusCard>
  )
}

const markGoalBlockedToolCard: ToolCardRenderer = {
  toolName: "mark_goal_blocked",
  collapsedSummary,
  renderExpanded
}

export default markGoalBlockedToolCard

export const examples: ToolCardExample[] = [
  {
    id: "blocked_with_details",
    label: "Blocked with structured details",
    input: {
      reason: "Waiting for **repository access**. See JOB-42 and https://example.test/access.",
      details: { provider: "github", permission: "contents:write" }
    },
    parsedResult: {
      goal_id: 17,
      status: "blocked",
      previous_status: "active",
      reason: "Waiting for **repository access**. See JOB-42 and https://example.test/access.",
      details: { provider: "github", permission: "contents:write" },
      chat_session_id: 8,
      chat_title: "Release planning",
      chat_path: "/chats/8"
    }
  },
  {
    id: "no_active_goal",
    label: "Error: no active goal",
    input: { reason: "Waiting for input" },
    resultError: true,
    resultBody: "active goal not found"
  }
]

import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EntityReference, numberValue, Row, SectionLabel } from "./toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "./chatHelperToolCard"
import i18n from "../../i18n"

type ChatPinResult = {
  sessionId: string
  title: string
  pinned: boolean
  message: string
  position: number | null
}

function parseChatPin(context: ToolCardContext, fallbackError: string, expectedPinned: boolean) {
  if (!context.resultError && context.resultSettled === false) return { kind: "pending" as const }

  return successOrError<ChatPinResult>(context, fallbackError, (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    const message = displayValue(parsed.message)
    if (!sessionId || !title || parsed.pinned !== expectedPinned || !message) return null
    const position = numberValue(parsed.position ?? parsed.pinned_position)
    return { sessionId, title, pinned: parsed.pinned, message, position }
  })
}

function requestedChatId(context: ToolCardContext) {
  return displayValue(context.input?.chat_session_id)
}

function ChatReference({ id, label = i18n.t("chat:tool_card_chat") }: { id: string; label?: string }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <EntityReference id={id} kind="chat" />
    </div>
  )
}

function errorMessage(context: ToolCardContext, fallback: string) {
  if (context.parsedResult && typeof context.parsedResult === "object" && !Array.isArray(context.parsedResult)) {
    const result = context.parsedResult as Record<string, unknown>
    return displayValue(result.message) ?? displayValue(result.error) ?? displayValue(result.code) ?? fallback
  }
  return displayValue(context.resultBody) ?? fallback
}

export function chatPinToolCard(toolName: "pin_chat" | "unpin_chat"): ToolCardRenderer {
  const expectedPinned = toolName === "pin_chat"
  const title = expectedPinned ? i18n.t("chat:chat_pin_title") : i18n.t("chat:chat_unpin_title")
  const errorSummary = expectedPinned ? i18n.t("chat:chat_pin_failed") : i18n.t("chat:chat_unpin_failed")
  const malformedSummary = expectedPinned ? i18n.t("chat:chat_pin_malformed") : i18n.t("chat:chat_unpin_malformed")

  return {
    toolName,
    collapsedSummary(context) {
      const parsed = parseChatPin(context, `${errorSummary}.`, expectedPinned)
      if (parsed.kind === "error") return errorSummary
      if (parsed.kind === "malformed") return malformedSummary
      if (parsed.kind === "pending") return expectedPinned ? i18n.t("chat:chat_pinning") : i18n.t("chat:chat_unpinning")
      return parsed.data.message
    },
    renderExpanded(context) {
      const parsed = parseChatPin(context, `${errorSummary}.`, expectedPinned)
      if (parsed.kind === "error") return <ErrorCard title={title} message={errorMessage(context, parsed.message)} />
      if (parsed.kind === "malformed") return <MalformedCard title={title} />
      if (parsed.kind === "pending") {
        const targetId = requestedChatId(context)
        return (
          <StatusCard title={title} status="pending">
            {targetId ? <ChatReference id={targetId} label={i18n.t("chat:tool_card_requested_target")} /> : <Row label={i18n.t("chat:tool_card_requested_target")} value={i18n.t("chat:tool_card_current_chat")} />}
          </StatusCard>
        )
      }

      return (
        <StatusCard title={title} status={parsed.data.pinned ? "pinned" : "unpinned"}>
          <dl className="grid gap-1 sm:grid-cols-2">
            {requestedChatId(context) ? <ChatReference id={requestedChatId(context)!} label={i18n.t("chat:tool_card_requested_target")} /> : null}
            <ChatReference id={parsed.data.sessionId} />
            <div className="min-w-0">
              <SectionLabel>{i18n.t("chat:title")}</SectionLabel>
              <EntityReference className="whitespace-normal break-words" id={parsed.data.sessionId} kind="chat" label={parsed.data.title} wrap="break" />
            </div>
            <Row label={i18n.t("chat:tool_card_state")} value={parsed.data.pinned ? i18n.t("chat:chat_pinned") : i18n.t("chat:chat_unpinned")} />
            {parsed.data.position != null ? <Row label={i18n.t("chat:tool_card_position")} value={String(parsed.data.position)} /> : null}
            <Row label={i18n.t("chat:tool_card_result")} value={parsed.data.message} />
          </dl>
        </StatusCard>
      )
    }
  }
}

export function chatPinToolCardExamples(toolName: "pin_chat" | "unpin_chat"): ToolCardExample[] {
  const pinned = toolName === "pin_chat"
  return [
    {
      id: "explicit_target",
      label: pinned ? i18n.t("chat:chat_pin_example") : i18n.t("chat:chat_unpin_example"),
      input: { chat_session_id: 42 },
      parsedResult: {
        session_id: 42,
        title: i18n.t("chat:chat_pin_example_title"),
        pinned,
        message: pinned ? i18n.t("chat:chat_pinned_message") : i18n.t("chat:chat_unpinned_message")
      },
      sourceType: "generic"
    },
    {
      id: "pending",
      label: pinned ? i18n.t("chat:chat_pin_pending") : i18n.t("chat:chat_unpin_pending"),
      input: { chat_session_id: 42 },
      parsedResult: null,
      resultSettled: false,
      sourceType: "generic"
    },
    {
      id: "empty_result",
      label: pinned ? i18n.t("chat:chat_pin_empty") : i18n.t("chat:chat_unpin_empty"),
      input: { chat_session_id: 42 },
      parsedResult: null,
      sourceType: "generic"
    },
    {
      id: "not_authorized",
      label: i18n.t("chat:not_authorized"),
      parsedResult: { error: "not_authorized" },
      resultError: true,
      sourceType: "generic"
    }
  ]
}

import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { displayValue, EmptyState, EntityReference, numberValue, Row, SectionLabel } from "../toolCardUi"
import { MarkdownPreview } from "../toolCardMarkdown"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type SendChatMessageResult = {
  threadId: string
  state: string
  hopCount: number | null
  maxHops: number | null
  hopsRemaining: number | null
  targetChatSessionId: string
  messageId: string
}

function parseSendChatMessage(context: ToolCardContext) {
  return successOrError<SendChatMessageResult>(context, i18n.t("chat:tool_card_cross_chat_failed_period"), (parsed) => {
    const threadId = displayValue(parsed.thread_id)
    const targetChatSessionId = displayValue(parsed.target_chat_session_id)
    const messageId = displayValue(parsed.message_id)
    const state = displayValue(parsed.state)
    if (!threadId || !targetChatSessionId || !messageId || !state) return null

    return {
      threadId,
      state,
      hopCount: numberValue(parsed.hop_count),
      maxHops: numberValue(parsed.max_hops),
      hopsRemaining: numberValue(parsed.hops_remaining),
      targetChatSessionId,
      messageId
    }
  })
}

function requestIsPending(context: ToolCardContext) {
  return context.parsedResult == null && !context.resultBody.trim()
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseSendChatMessage(context)
  if (parsed.kind === "error") return i18n.t("chat:tool_card_cross_chat_failed")
  if (parsed.kind === "malformed")
    return requestIsPending(context) ? i18n.t("chat:tool_card_cross_chat_pending") : i18n.t("chat:tool_card_cross_chat_unexpected")
  return i18n.t("chat:tool_card_cross_chat_sent", { chatId: parsed.data.targetChatSessionId, threadId: parsed.data.threadId })
}

function MessageText({ context }: { context: ToolCardContext }) {
  const text = typeof context.input?.text === "string" ? context.input.text : ""
  return (
    <div className="min-w-0 max-w-full">
      <SectionLabel>{i18n.t("chat:tool_card_message")}</SectionLabel>
      <MarkdownPreview
        emptyState={<EmptyState>{i18n.t("chat:tool_card_cross_chat_no_text")}</EmptyState>}
        linkifySlugs
        linkifyUrls
        maxChars={500}
        maxLines={4}
        modalLabel={i18n.t("chat:tool_card_sent_message")}
        onLinkClick={context.onLinkClick}
        text={text}
      />
    </div>
  )
}

function RequestRouting({ context }: { context: ToolCardContext }) {
  const targetChatSessionId = displayValue(context.input?.target_chat_session_id)
  const threadId = displayValue(context.input?.thread_id)
  const maxHops = numberValue(context.input?.max_hops)
  if (!targetChatSessionId && !threadId && maxHops == null) return null

  return (
    <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
      {targetChatSessionId ? (
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:tool_card_requested_target")}</SectionLabel>
          <EntityReference id={targetChatSessionId} kind="chat" />
        </div>
      ) : null}
      {threadId ? <Row label={i18n.t("chat:tool_card_requested_thread")} value={`#${threadId}`} /> : null}
      {maxHops != null ? <Row label={i18n.t("chat:tool_card_requested_hop_cap")} value={String(maxHops)} /> : null}
    </dl>
  )
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseSendChatMessage(context)
  if (parsed.kind === "error") return <ErrorCard title={i18n.t("chat:tool_card_cross_chat_message")} message={parsed.message} />
  if (parsed.kind === "malformed") {
    if (requestIsPending(context)) {
      return (
        <StatusCard title={i18n.t("chat:tool_card_cross_chat_message")} status="pending">
          <MessageText context={context} />
          <RequestRouting context={context} />
          <EmptyState>{i18n.t("chat:tool_card_cross_chat_waiting")}</EmptyState>
        </StatusCard>
      )
    }
    return <MalformedCard title={i18n.t("chat:tool_card_cross_chat_message")} />
  }

  const messageHref = `/chats/${parsed.data.targetChatSessionId}#message-${parsed.data.messageId}`

  return (
    <StatusCard title={i18n.t("chat:tool_card_cross_chat_message")} status={parsed.data.state}>
      <MessageText context={context} />
      <RequestRouting context={context} />
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:tool_card_target_chat")}</SectionLabel>
          <EntityReference id={parsed.data.targetChatSessionId} kind="chat" />
        </div>
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:tool_card_sent_message")}</SectionLabel>
          <EntityReference
            href={messageHref}
            id={parsed.data.targetChatSessionId}
            kind="chat"
            label={i18n.t("chat:tool_card_message_number", { id: parsed.data.messageId })}
          />
        </div>
        <Row label={i18n.t("chat:tool_card_thread")} value={`#${parsed.data.threadId}`} />
        {parsed.data.hopCount != null && parsed.data.maxHops != null ? (
          <Row label={i18n.t("chat:tool_card_hops_used")} value={`${parsed.data.hopCount} / ${parsed.data.maxHops}`} />
        ) : null}
        {parsed.data.hopsRemaining != null ? <Row label={i18n.t("chat:tool_card_hops_left")} value={String(parsed.data.hopsRemaining)} /> : null}
      </dl>
    </StatusCard>
  )
}

const sendChatMessageToolCard: ToolCardRenderer = {
  toolName: "send_chat_message",
  collapsedSummary,
  renderExpanded
}

export default sendChatMessageToolCard

export const examples: ToolCardExample[] = [
  {
    id: "open_thread",
    label: i18n.t("chat:tool_card_cross_chat_example_sent"),
    input: { text: "Please review **JOB-42** at https://example.test/context.", target_chat_session_id: 42, max_hops: 6 },
    parsedResult: { thread_id: 7, state: "open", hop_count: 1, max_hops: 6, hops_remaining: 5, target_chat_session_id: 42, message_id: 99 }
  },
  {
    id: "same_chat_error",
    label: i18n.t("chat:tool_card_cross_chat_example_same"),
    input: { text: "Hello", target_chat_session_id: 42 },
    resultError: true,
    resultBody: "cannot open a bridge thread to the same chat"
  },
  { id: "pending", label: i18n.t("chat:tool_card_cross_chat_example_pending"), input: { text: "Waiting to send", thread_id: 7 }, resultBody: "" }
]

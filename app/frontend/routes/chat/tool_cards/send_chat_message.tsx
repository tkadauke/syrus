import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
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
  return successOrError<SendChatMessageResult>(context, "Sending the chat message failed.", (parsed) => {
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
  if (parsed.kind === "error") return "Cross-chat message failed"
  if (parsed.kind === "malformed") return requestIsPending(context) ? "Cross-chat message pending" : "Cross-chat message returned an unexpected response"
  return `Sent to CHAT-${parsed.data.targetChatSessionId} (thread #${parsed.data.threadId})`
}

function MessageText({ context }: { context: ToolCardContext }) {
  const text = typeof context.input?.text === "string" ? context.input.text : ""
  return (
    <div className="min-w-0 max-w-full">
      <SectionLabel>Message</SectionLabel>
      <MarkdownPreview
        emptyState={<EmptyState>No message text was included with this transcript entry.</EmptyState>}
        linkifySlugs
        linkifyUrls
        maxChars={500}
        maxLines={4}
        modalLabel="Sent message"
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
          <SectionLabel>Requested target</SectionLabel>
          <EntityReference id={targetChatSessionId} kind="chat" />
        </div>
      ) : null}
      {threadId ? <Row label="Requested thread" value={`#${threadId}`} /> : null}
      {maxHops != null ? <Row label="Requested hop cap" value={String(maxHops)} /> : null}
    </dl>
  )
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseSendChatMessage(context)
  if (parsed.kind === "error") return <ErrorCard title="Cross-chat message" message={parsed.message} />
  if (parsed.kind === "malformed") {
    if (requestIsPending(context)) {
      return (
        <StatusCard title="Cross-chat message" status="pending">
          <MessageText context={context} />
          <RequestRouting context={context} />
          <EmptyState>Waiting for the message to be sent.</EmptyState>
        </StatusCard>
      )
    }
    return <MalformedCard title="Cross-chat message" />
  }

  const messageHref = `/chats/${parsed.data.targetChatSessionId}#message-${parsed.data.messageId}`

  return (
    <StatusCard title="Cross-chat message" status={parsed.data.state}>
      <MessageText context={context} />
      <RequestRouting context={context} />
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        <div className="min-w-0">
          <SectionLabel>Target chat</SectionLabel>
          <EntityReference id={parsed.data.targetChatSessionId} kind="chat" />
        </div>
        <div className="min-w-0">
          <SectionLabel>Sent message</SectionLabel>
          <EntityReference href={messageHref} id={parsed.data.targetChatSessionId} kind="chat" label={`Message #${parsed.data.messageId}`} />
        </div>
        <Row label="Thread" value={`#${parsed.data.threadId}`} />
        {parsed.data.hopCount != null && parsed.data.maxHops != null ? (
          <Row label="Hops used" value={`${parsed.data.hopCount} / ${parsed.data.maxHops}`} />
        ) : null}
        {parsed.data.hopsRemaining != null ? <Row label="Hops left" value={String(parsed.data.hopsRemaining)} /> : null}
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
    label: "Message sent to an open thread",
    input: { text: "Please review **JOB-42** at https://example.test/context.", target_chat_session_id: 42, max_hops: 6 },
    parsedResult: { thread_id: 7, state: "open", hop_count: 1, max_hops: 6, hops_remaining: 5, target_chat_session_id: 42, message_id: 99 }
  },
  {
    id: "same_chat_error",
    label: "Error: target is the current chat",
    input: { text: "Hello", target_chat_session_id: 42 },
    resultError: true,
    resultBody: "cannot open a bridge thread to the same chat"
  },
  { id: "pending", label: "Pending message", input: { text: "Waiting to send", thread_id: 7 }, resultBody: "" }
]

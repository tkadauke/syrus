import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, numberValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type SendChatMessageResult = {
  threadId: string
  state: string
  hopCount: number | null
  maxHops: number | null
  targetChatSessionId: string
}

function parseSendChatMessage(context: ToolCardContext) {
  return successOrError<SendChatMessageResult>(context, "Sending the chat message failed.", (parsed) => {
    const threadId = displayValue(parsed.thread_id)
    const targetChatSessionId = displayValue(parsed.target_chat_session_id)
    const state = displayValue(parsed.state)
    if (!threadId || !targetChatSessionId || !state) return null

    return {
      threadId,
      state,
      hopCount: numberValue(parsed.hop_count),
      maxHops: numberValue(parsed.max_hops),
      targetChatSessionId
    }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseSendChatMessage(context)
  if (parsed.kind === "error") return "Cross-chat message failed"
  if (parsed.kind === "malformed") return "Cross-chat message returned an unexpected response"
  return `Sent to chat #${parsed.data.targetChatSessionId} (thread #${parsed.data.threadId})`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseSendChatMessage(context)
  if (parsed.kind === "error") return <ErrorCard title="Cross-chat message" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Cross-chat message" />

  return (
    <StatusCard title="Cross-chat message" status={parsed.data.state}>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Target chat" value={`#${parsed.data.targetChatSessionId}`} />
        <Row label="Thread" value={`#${parsed.data.threadId}`} />
        {parsed.data.hopCount != null && parsed.data.maxHops != null ? (
          <Row label="Hops" value={`${parsed.data.hopCount} / ${parsed.data.maxHops}`} />
        ) : null}
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

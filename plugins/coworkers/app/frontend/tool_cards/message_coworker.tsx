import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, Row, StatePill } from "@app/routes/chat/toolCardUi"

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function collapsedSummary(context: ToolCardContext) {
  const result = context.parsedResult
  if (!isPlainObject(result) || result.queued !== true || typeof result.to_handle !== "string") return null
  return `Queued for @${result.to_handle}`
}

function renderExpanded(context: ToolCardContext) {
  const result = context.parsedResult
  if (!isPlainObject(result)) return <EmptyState>{context.resultBody || "Message could not be queued."}</EmptyState>
  if (result.queued !== true) return <EmptyState>{context.resultBody || "Message could not be queued."}</EmptyState>

  return (
    <CardShell>
      <Row label="Delivery" value={<StatePill state="Queued" tone="info" />} />
      <Row label="From" value={typeof result.from_handle === "string" ? `@${result.from_handle}` : "—"} />
      <Row label="To" value={typeof result.to_handle === "string" ? `@${result.to_handle}` : "—"} />
    </CardShell>
  )
}

const messageCoworkerCard: ToolCardRenderer = {
  toolName: "message_coworker",
  collapsedSummary,
  renderExpanded
}

export default messageCoworkerCard

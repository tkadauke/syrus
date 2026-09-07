import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "@app/routes/chat/toolCardUi"

// Plugin-owned tool card for delete_memory (EPIC-293). delete_memory's
// response `{ id, deleted: true }` doesn't echo the memory content -- there
// is nothing left to preview once it's soft-deleted, just the confirmation.
type DeleteMemoryResult = { id: string; deleted: boolean }

function parseResult(context: ToolCardContext): DeleteMemoryResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const id = displayValue(parsed.id)
  if (!id || typeof parsed.deleted !== "boolean") return null

  return { id, deleted: parsed.deleted }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return result.deleted ? `Deleted memory #${result.id}` : `Memory #${result.id} not deleted`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null

  return (
    <CardShell>
      <Row label="Memory ID" value={result.id} />
      <Row label="Status" value={result.deleted ? "Deleted" : "Not deleted"} />
    </CardShell>
  )
}

const deleteMemoryToolCard: ToolCardRenderer = {
  toolName: "delete_memory",
  collapsedSummary,
  renderExpanded
}

export default deleteMemoryToolCard

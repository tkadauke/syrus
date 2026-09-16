import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, StatePill } from "../toolCardUi"

// Core-owned tool card for set_bookmark. Supersedes the legacy
// typedToolResult("set_bookmark") special case in toolRendering.ts (same
// migration read_job/propose_job already went through).
type SetBookmarkResult = {
  id: string | null
  label: string
  kind: string | null
  messageId: string | null
  anchor: string | null
}

function parseResult(parsed: unknown): SetBookmarkResult | null {
  if (!isPlainObject(parsed)) return null
  const label = displayValue(parsed.label)
  if (!label) return null

  return {
    id: displayValue(parsed.id),
    label,
    kind: displayValue(parsed.kind),
    messageId: displayValue(parsed.message_id),
    anchor: displayValue(parsed.anchor)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context.parsedResult)
  if (!result) return null

  return `Bookmark added: ${result.label}${result.kind ? ` (${result.kind})` : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context.parsedResult)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="added" tone="success" />
        {result.kind ? <Badge>{result.kind}</Badge> : null}
        {result.id ? <Badge>#{result.id}</Badge> : null}
      </div>
      <Row label="Label" value={result.label} />
      {result.anchor ? <Row label="Anchor" value={result.anchor} /> : null}
      {result.messageId ? <Row label="Message" value={`#${result.messageId}`} /> : null}
    </CardShell>
  )
}

const setBookmarkToolCard: ToolCardRenderer = {
  toolName: "set_bookmark",
  collapsedSummary,
  renderExpanded
}

export default setBookmarkToolCard

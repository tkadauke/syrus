import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, Row, StatePill } from "@app/routes/chat/toolCardUi"

function resultPath(context: ToolCardContext) {
  if (typeof context.parsedResult !== "object" || context.parsedResult === null || Array.isArray(context.parsedResult)) return null
  const result = context.parsedResult as Record<string, unknown>
  if (typeof result.path === "string") return result.path
  if (typeof result.destination === "string") return result.destination
  return null
}

export function workspaceFileToolCard(toolName: string, verb: string): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary: (context) => {
      const path = resultPath(context)
      return path ? `${verb} ${path}` : null
    },
    renderExpanded: (context) => {
      const path = resultPath(context)
      if (!path) return <EmptyState>{context.resultBody || "Workspace operation failed."}</EmptyState>
      return (
        <CardShell>
          <Row label="Status" value={<StatePill state={verb} tone="success" />} />
          <Row label="Workspace path" value={path} />
        </CardShell>
      )
    }
  }
}

import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parsePreviewPanel, PreviewErrorCard, PreviewPanelCard, previewError, previewPanelSummary, previewPanelText } from "../previewPanelToolCard"

// Plugin-owned tool card for show_preview (the pending-action tool-card work). Lives
// entirely inside the mockups plugin -- core discovers it by directory
// convention (see app/frontend/pluginToolCards.tsx) and never imports it by
// name, so it can be added, changed, or removed without touching core.
function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_preview"), error })
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? previewPanelSummary(panel) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title={previewPanelText("tool_preview")} />
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? <PreviewPanelCard panel={panel} /> : null
}

const showPreviewToolCard: ToolCardRenderer = {
  toolName: "show_preview",
  collapsedSummary,
  renderExpanded
}

export default showPreviewToolCard

export const examples: ToolCardExample[] = [
  {
    id: "open_empty",
    label: "Open empty panel",
    input: { title: "Checkout redesign" },
    parsedResult: { panel_id: "42", title: "Checkout redesign", state: "open", file_count: 0, note: "Write **index.html** next." }
  },
  {
    id: "published",
    label: "Published preview",
    parsedResult: {
      panel_id: "42",
      title: "Checkout redesign",
      state: "open",
      url: "https://preview.example.test",
      file_count: 3,
      version_id: "9",
      entry_file: "index.html",
      mockup_slug: "MOCKUP-42"
    }
  },
  {
    id: "error",
    label: "Publish error",
    input: { panel_id: "42", title: "Checkout redesign" },
    resultBody: "Error: No files found in panel 42",
    resultError: true
  }
]

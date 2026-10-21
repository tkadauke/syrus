import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EntityReference, InternalLink, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { parsePreviewPanel, PreviewErrorCard, previewError, previewPanelSummary, previewPanelText, type PreviewPanel } from "../previewPanelToolCard"

function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_close_preview"), error })
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? previewPanelSummary(panel) : null
}

function ClosedPreviewCard({ panel }: { panel: PreviewPanel }) {
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference kind="preview_panel" label={previewPanelText("tool_panel_number", { id: panel.panelId })} slug={panel.panelId} wrap="nowrap" />
        <StatePill state={previewPanelText("tool_closed")} tone="neutral" />
      </div>
      {panel.title ? <div className="break-words text-sm font-semibold text-text-primary">{panel.title}</div> : null}
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        {panel.entryFile ? <Row label={previewPanelText("tool_entry_file")} value={panel.entryFile} /> : null}
        {panel.fileCount != null ? <Row label={previewPanelText("tool_files")} value={String(panel.fileCount)} /> : null}
        {panel.versionId ? <Row label={previewPanelText("tool_version")} value={panel.versionId} /> : null}
      </div>
      {panel.mockupSlug ? <InternalLink href={`/mockups/${panel.mockupSlug}`}>{previewPanelText("tool_open_mockup")}</InternalLink> : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title={previewPanelText("tool_close_preview")} />
  const panel = parsePreviewPanel(context.parsedResult, context.input)
  return panel ? <ClosedPreviewCard panel={panel} /> : null
}

const closePreviewToolCard: ToolCardRenderer = {
  toolName: "close_preview",
  collapsedSummary,
  renderExpanded
}

export default closePreviewToolCard

export const examples: ToolCardExample[] = [
  {
    id: "closed_published",
    label: "Closed published panel",
    input: { panel_id: "42", title: "Checkout redesign" },
    parsedResult: {
      panel_id: "42",
      title: "Checkout redesign",
      state: "closed",
      url: "https://preview.example.test",
      file_count: 3,
      version_id: "9",
      entry_file: "index.html",
      mockup_slug: "MOCKUP-42"
    }
  },
  {
    id: "closed_empty",
    label: "Closed empty panel",
    input: { panel_id: "43", title: "Empty draft" },
    parsedResult: { panel_id: "43", state: "closed", file_count: 0 }
  },
  {
    id: "not_found",
    label: "Panel not found",
    input: { panel_id: "404", title: "Missing panel" },
    resultBody: 'Error: No open preview panel "404" for this chat.',
    resultError: true
  }
]

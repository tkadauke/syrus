import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell } from "@app/routes/chat/mediaPreviewShell"
import { normalizedToolCardContentBlocks } from "@app/routes/chat/toolRendering"
import { Badge, CardShell, displayValue, EntityReference, Row } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import { PreviewErrorCard, previewError, previewPanelText } from "../previewPanelToolCard"

type Rendered = { panelId: string; entryFile: string | null; viewport: string | null; capture: string | null; waitMs: string | null; image: string | null }

function parseRendered(context: ToolCardContext): Rendered | null {
  const blocks = normalizedToolCardContentBlocks(context.parsedResult)
  const textBlock = blocks.find((block) => block.type === "text" && typeof block.text === "string")
  let meta: unknown = null
  try {
    meta = textBlock ? JSON.parse(String(textBlock.text)) : null
  } catch {
    // handled-error-expected: the text block is only optional metadata; a non-JSON body means no card.
    meta = null
  }
  if (!isPlainObject(meta)) return null
  const panelId = displayValue(meta.panel_id)
  if (!panelId) return null
  const image = blocks.find((block) => block.type === "image" && typeof block.data === "string")
  const mime = image ? displayValue(image.mimeType) || "image/png" : null
  const viewport = isPlainObject(meta.viewport) ? `${meta.viewport.width}×${meta.viewport.height}` : null
  return {
    panelId,
    entryFile: displayValue(meta.entry_file),
    viewport: displayValue(meta.preset) ? `${meta.preset} (${viewport})` : viewport,
    capture: displayValue(meta.capture),
    waitMs: displayValue(meta.wait_ms),
    image: image ? `data:${mime};base64,${image.data}` : null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const error = previewError(context)
  if (error) return previewPanelText("tool_failed_summary", { operation: previewPanelText("tool_render_preview"), error })
  const rendered = parseRendered(context)
  return rendered ? previewPanelText("tool_rendered_summary", { id: rendered.panelId }) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <PreviewErrorCard context={context} title={previewPanelText("tool_render_preview")} />
  const rendered = parseRendered(context)
  if (!rendered) return null
  const title = previewPanelText("tool_render_preview")
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference kind="preview_panel" label={previewPanelText("tool_panel_number", { id: rendered.panelId })} slug={rendered.panelId} wrap="nowrap" />
        <Badge>{previewPanelText("tool_unpublished")}</Badge>
      </div>
      {rendered.image ? (
        <MediaPreviewShell
          item={{ title, subtitle: rendered.entryFile, src: rendered.image, alt: title, badge: "PNG", actions: [], meta: [] }}
          modalLabel={title}
        />
      ) : null}
      <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
        {rendered.entryFile ? <Row label={previewPanelText("tool_entry_file")} value={rendered.entryFile} /> : null}
        {rendered.viewport ? <Row label={previewPanelText("tool_viewport")} value={rendered.viewport} /> : null}
        {rendered.capture ? <Row label={previewPanelText("tool_capture")} value={rendered.capture} /> : null}
        {rendered.waitMs ? <Row label={previewPanelText("tool_wait_ms")} value={rendered.waitMs} /> : null}
      </dl>
    </CardShell>
  )
}

const renderPreviewToolCard: ToolCardRenderer = {
  toolName: "render_preview",
  collapsedSummary,
  renderExpanded
}

export default renderPreviewToolCard

export const examples: ToolCardExample[] = [
  {
    id: "mobile_render",
    label: "Mobile render",
    input: { panel_id: "42", viewport: "mobile" },
    parsedResult: [
      { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
      {
        type: "text",
        text: JSON.stringify({
          panel_id: 42,
          entry_file: "index.html",
          viewport: { width: 393, height: 852 },
          preset: "mobile",
          capture: "viewport",
          wait_ms: 0,
          published: false
        })
      }
    ]
  },
  {
    id: "not_found",
    label: "Panel not found",
    input: { panel_id: "404" },
    resultBody: 'Error: No open preview panel "404" for this chat.',
    resultError: true
  }
]

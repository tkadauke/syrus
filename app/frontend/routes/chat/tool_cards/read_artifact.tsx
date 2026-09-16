import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction } from "../mediaPreviewShell"
import { CardShell, displayValue, StatePill } from "../toolCardUi"

type ArtifactImage = {
  dataUrl: string
  mimeType: string
}

// read_artifact's success result is a raw MCP image content block (no JSON
// text wrapper), so the chat pipeline's parsedToolResult hands this card the
// content array itself rather than a parsed-JSON object -- see
// Mcp::Tools.image_result and app/frontend/routes/chat/toolRendering.ts.
function imageContent(context: ToolCardContext): ArtifactImage | null {
  const content = context.parsedResult
  if (!Array.isArray(content)) return null

  const item = content.find((entry) => isPlainObject(entry) && entry.type === "image")
  if (!isPlainObject(item)) return null

  const data = displayValue(item.data)
  if (!data) return null
  const mimeType = displayValue(item.mimeType) || "image/png"

  return { dataUrl: data.startsWith("data:image/") ? data : `data:${mimeType};base64,${data}`, mimeType }
}

export function readArtifactSummary(context: ToolCardContext) {
  const type = displayValue(context.input?.type)
  if (context.resultError) return type ? `Failed to read artifact: ${type}` : "Failed to read artifact"
  if (!imageContent(context)) return null
  return type ? `Artifact: ${type}` : "Artifact image"
}

function ReadArtifactCard({ context, image }: { context: ToolCardContext; image: ArtifactImage }) {
  const type = displayValue(context.input?.type) || "Artifact"
  const workflowId = displayValue(context.input?.workflow_id)

  const actions: MediaPreviewAction[] = [
    { label: "Open", href: image.dataUrl },
    { label: "Download", href: image.dataUrl, download: true }
  ]

  return (
    <CardShell>
      <MediaPreviewShell
        item={{
          title: type,
          subtitle: workflowId ? `Workflow ${workflowId}` : null,
          src: image.dataUrl,
          alt: type,
          badge: image.mimeType.split("/").pop()?.toUpperCase() ?? "IMAGE",
          actions,
          meta: [
            { label: "Type", value: type },
            { label: "Workflow", value: workflowId },
            { label: "Content type", value: image.mimeType }
          ]
        }}
        modalLabel={type}
      />
    </CardShell>
  )
}

export function renderReadArtifact(context: ToolCardContext) {
  if (context.resultError) {
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state="failed" tone="failure" />
          <span className="font-semibold text-gray-900 dark:text-gray-100">Read artifact</span>
        </div>
        <div className="text-red-700 dark:text-red-300">{context.resultBody}</div>
      </CardShell>
    )
  }

  const image = imageContent(context)
  return image ? <ReadArtifactCard context={context} image={image} /> : null
}

const readArtifactToolCard: ToolCardRenderer = {
  toolName: "read_artifact",
  collapsedSummary: readArtifactSummary,
  renderExpanded: renderReadArtifact
}

export default readArtifactToolCard

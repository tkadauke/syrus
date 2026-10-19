import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { displayValue } from "@app/routes/chat/toolCardUi"
import { toolCardPayloadSizeLabel } from "@app/toolCardSecurity"
import { ElementFailureCard, elementActionSummary, elementFailureSummary, makeElementCard, parseElementResult, t } from "../whiteboardToolCard"

const fallbackCard = makeElementCard("draw_image", "tool_action_drew_image")

function safeImageUrl(value: unknown): string | null {
  if (typeof value !== "string") return null
  if (/^data:image\/[a-z0-9.+-]+(?:;[a-z0-9.+-]+=[^;,]*)*(?:;base64)?,/i.test(value)) return value
  try {
    const url = new URL(value)
    return url.protocol === "http:" || url.protocol === "https:" ? value : null
  } catch {
    return null
  }
}

function imageSizeLabel(url: string): string | null {
  return url.startsWith("data:") ? `≈${toolCardPayloadSizeLabel(url)}` : null
}

function DrawImageCard({ context }: { context: ToolCardContext }) {
  const action = t("tool_action_drew_image")
  if (context.resultError) return <ElementFailureCard action={action} context={context} />
  const result = parseElementResult(context.parsedResult)
  if (!result) return fallbackCard.renderExpanded(context)

  const input = isPlainObject(context.input) ? context.input : {}
  const src = safeImageUrl(input.data_url)
  const mimeType = displayValue(input.mime_type)
  const inputFileId = displayValue(input.file_id)
  const x = displayValue(input.x),
    y = displayValue(input.y),
    width = displayValue(input.width),
    height = displayValue(input.height)
  const size = src ? imageSizeLabel(src) : null
  const title = result.fileId ?? inputFileId ?? t("tool_image")
  const details = [
    [t("tool_field_mime_type"), mimeType],
    ["Size", size],
    [t("tool_field_file_id"), inputFileId],
    ["X", x],
    ["Y", y],
    [t("tool_field_width"), width],
    [t("tool_field_height"), height]
  ].filter((detail): detail is string[] => Boolean(detail[1]))
  const rows: CompactActionRow[] = details.length
    ? [
        {
          label: t("tool_details"),
          value: (
            <>
              {details.map(([label, value]) => (
                <span key={label}>
                  <span className="text-text-subtle">{label}:</span> <span className="font-mono">{value}</span>
                </span>
              ))}
            </>
          )
        }
      ]
    : []
  if (result.fileId) rows.push({ label: t("tool_field_file_id"), value: <span className="font-mono">{result.fileId}</span> })

  return (
    <CompactActionCard
      action={action}
      badges={result.version != null ? [`v${result.version}`] : []}
      entity={<span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>}
      media={
        src
          ? {
              modalLabel: t("tool_image"),
              item: {
                title,
                src,
                alt: t("tool_image"),
                badge: mimeType,
                subtitle: size,
                actions: [{ label: "Download", href: src, download: true }],
                meta: [
                  { label: "Element ID", value: result.id, copyValue: result.id },
                  { label: "Version", value: result.version == null ? null : String(result.version) },
                  { label: "File ID", value: result.fileId ?? inputFileId, copyValue: result.fileId ?? inputFileId },
                  { label: "MIME type", value: mimeType },
                  { label: "Approx. size", value: size },
                  { label: "Dimensions", value: width && height ? `${width} × ${height}` : (width ?? height) },
                  { label: "Position", value: x && y ? `${x}, ${y}` : (x ?? y) }
                ]
              }
            }
          : undefined
      }
      rows={rows}
      tone="success"
    />
  )
}

const drawImageCard: ToolCardRenderer = {
  toolName: "draw_image",
  collapsedSummary(context) {
    const action = t("tool_action_drew_image")
    const failure = elementFailureSummary(context, action)
    if (failure) return failure
    const result = parseElementResult(context.parsedResult)
    return result
      ? elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
      : (fallbackCard.collapsedSummary?.(context) ?? action)
  },
  renderExpanded(context) {
    return <DrawImageCard context={context} />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "image_preview",
    label: "Image preview",
    input: { data_url: "data:image/png;base64,iVBORw0KGgo=", mime_type: "image/png", file_id: "source-image", x: 20, y: 30, width: 320, height: 180 },
    parsedResult: { result: { id: "image-element", file_id: "canvas-image", version: 2 } }
  },
  { id: "pending", label: "Pending result", input: { data_url: "https://example.com/image.png", mime_type: "image/png" }, resultBody: "" },
  { id: "failure", label: "Failed image", input: { file_id: "source-image" }, parsedResult: { message: "Image could not be drawn" }, resultError: true }
]

export default drawImageCard

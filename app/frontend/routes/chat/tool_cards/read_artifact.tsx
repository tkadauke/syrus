import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction } from "../mediaPreviewShell"
import { normalizedToolCardContentBlocks } from "../toolRendering"
import { CardShell, displayValue, EmptyState, EntityReference, Row, StatePill } from "../toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type ArtifactImage = {
  dataUrl: string
  mimeType: string
}

function imageContent(context: ToolCardContext): ArtifactImage | null {
  const item = normalizedToolCardContentBlocks(context.parsedResult).find(
    (entry) => entry.type === "image" || entry.type === "input_image" || entry.type === "output_image"
  )
  if (!isPlainObject(item)) return null

  const source = isPlainObject(item.source) ? item.source : null
  const data = displayValue(item.data) || displayValue(item.dataUrl) || displayValue(item.image_url) || displayValue(source?.data)
  if (!data) return null
  const mimeType =
    displayValue(item.mimeType) ||
    displayValue(item.mime_type) ||
    displayValue(item.media_type) ||
    displayValue(source?.media_type) ||
    mimeTypeFromDataUrl(data) ||
    "image/png"

  return { dataUrl: data.startsWith("data:") ? data : `data:${mimeType};base64,${data}`, mimeType }
}

function mimeTypeFromDataUrl(value: string) {
  return value.match(/^data:([^;,]+)/)?.[1] ?? null
}

const failureConfig: ToolFailureConfig = {
  title: "Artifact read",
  attempted: (context) => {
    const type = displayValue(context.input?.type)
    return type ? `Read artifact ${type}` : "Read artifact"
  },
  retrySafety: "caution",
  recovery: "Verify the Workflow and artifact type with list_artifacts, then retry the read."
}

export function readArtifactSummary(context: ToolCardContext) {
  const type = displayValue(context.input?.type)
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  if (!imageContent(context)) return type ? `Artifact response: ${type}` : "Artifact response"
  return type ? `Artifact: ${type}` : "Artifact image"
}

function ReadArtifactCard({ context, image }: { context: ToolCardContext; image: ArtifactImage }) {
  const type = displayValue(context.input?.type) || "Artifact"
  const workflowId = resultField(context, "workflow_id") || displayValue(context.input?.workflow_id)
  const jobId = resultField(context, "job_id") || displayValue(context.input?.job_id)

  const actions: MediaPreviewAction[] = [
    { label: "Open", href: image.dataUrl },
    { label: "Download", href: image.dataUrl, download: true }
  ]

  return (
    <CardShell>
      <MediaPreviewShell
        item={{
          title: type,
          subtitle: workflowId ? `WF-${workflowId}` : null,
          src: image.dataUrl,
          alt: type,
          badge: image.mimeType.split("/").pop()?.toUpperCase() ?? "IMAGE",
          actions,
          meta: [
            { label: "Type", value: type },
            { label: "Content type", value: image.mimeType }
          ]
        }}
        modalLabel={type}
      />
      {workflowId ? (
        <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs">
          <span className="text-text-secondary">Workflow</span>
          <EntityReference id={workflowId} jobId={jobId} kind="workflow" />
        </div>
      ) : null}
    </CardShell>
  )
}

function resultField(context: ToolCardContext, key: string): string | null {
  const queue: unknown[] = [context.parsedResult]
  const visited = new Set<object>()
  while (queue.length > 0) {
    const value = queue.shift()
    if (!isPlainObject(value) || visited.has(value)) continue
    visited.add(value)
    const found = displayValue(value[key])
    if (found) return found
    for (const nestedKey of ["structured_content", "result", "output", "payload", "metadata"]) {
      if (value[nestedKey] != null) queue.push(value[nestedKey])
    }
  }
  return null
}

function textContent(context: ToolCardContext): string | null {
  const blockText = normalizedToolCardContentBlocks(context.parsedResult)
    .filter((block) => block.type === "text" || block.type === "output_text")
    .map((block) => displayValue(block.text) || displayValue(block.output))
    .filter((value): value is string => !!value)
    .join("\n")
  return blockText || displayValue(context.resultBody)
}

function ReadArtifactInfoCard({ context }: { context: ToolCardContext }) {
  const type = displayValue(context.input?.type)
  const workflowId = resultField(context, "workflow_id") || displayValue(context.input?.workflow_id)
  const jobId = resultField(context, "job_id") || displayValue(context.input?.job_id)
  const message = textContent(context)
  const pending = !message && context.parsedResult == null

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={pending ? "pending" : "empty"} tone={pending ? "info" : "neutral"} />
        <span className="break-words font-semibold text-gray-900 dark:text-gray-100">Read artifact</span>
      </div>
      {message ? (
        <div className="break-words text-sm text-text-secondary">{message}</div>
      ) : (
        <EmptyState>{pending ? "Waiting for the artifact result." : "The artifact result did not contain an image or message."}</EmptyState>
      )}
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {type ? <Row label="Type" value={type} /> : null}
        {workflowId ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase text-text-secondary">Workflow</div>
            <EntityReference id={workflowId} jobId={jobId} kind="workflow" />
          </div>
        ) : null}
      </dl>
    </CardShell>
  )
}

export function renderReadArtifact(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const image = imageContent(context)
  return image ? <ReadArtifactCard context={context} image={image} /> : <ReadArtifactInfoCard context={context} />
}

export const examples: ToolCardExample[] = [
  {
    id: "image_artifact",
    label: "Image artifact",
    input: { workflow_id: 28622, job_id: 7705, type: "visual_review_screenshot" },
    parsedResult: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }]
  },
  {
    id: "not_found",
    label: "Artifact not found",
    input: { workflow_id: 28622, type: "missing_screenshot" },
    resultBody: "Error: no image artifact found for type missing_screenshot",
    resultError: true
  },
  {
    id: "pending",
    label: "Pending result",
    input: { workflow_id: 28622, type: "visual_review_screenshot" }
  }
]

const readArtifactToolCard: ToolCardRenderer = {
  toolName: "read_artifact",
  collapsedSummary: readArtifactSummary,
  renderExpanded: renderReadArtifact
}

export default readArtifactToolCard

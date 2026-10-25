import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
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
  title: i18n.t("chat:tool_card_artifact_read"),
  attempted: (context) => {
    const type = displayValue(context.input?.type)
    return type ? i18n.t("chat:tool_card_artifact_attempt", { type }) : i18n.t("chat:tool_card_artifact_attempt_default")
  },
  retrySafety: "caution",
  recovery: i18n.t("chat:tool_card_artifact_recovery")
}

export function readArtifactSummary(context: ToolCardContext) {
  const type = displayValue(context.input?.type)
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary
  if (!imageContent(context)) return type ? i18n.t("chat:tool_card_artifact_response_type", { type }) : i18n.t("chat:tool_card_artifact_response")
  return type ? i18n.t("chat:tool_card_artifact_type_summary", { type }) : i18n.t("chat:tool_card_artifact_image")
}

function ReadArtifactCard({ context, image }: { context: ToolCardContext; image: ArtifactImage }) {
  const type = displayValue(context.input?.type) || i18n.t("chat:tool_card_artifact")
  const workflowId = resultField(context, "workflow_id") || displayValue(context.input?.workflow_id)
  const jobId = resultField(context, "job_id") || displayValue(context.input?.job_id)

  const actions: MediaPreviewAction[] = [
    { label: i18n.t("chat:tool_card_open"), href: image.dataUrl },
    { label: i18n.t("chat:tool_card_download"), href: image.dataUrl, download: true }
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
            { label: i18n.t("chat:tool_card_type"), value: type },
            { label: i18n.t("chat:tool_card_content_type"), value: image.mimeType }
          ]
        }}
        modalLabel={type}
      />
      {workflowId ? (
        <div className="flex min-w-0 flex-wrap items-center gap-2 text-xs">
          <span className="text-text-secondary">{i18n.t("chat:tool_card_workflow")}</span>
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
        <StatePill state={pending ? i18n.t("chat:tool_card_pending") : i18n.t("chat:tool_card_empty")} tone={pending ? "info" : "neutral"} />
        <span className="break-words font-semibold text-gray-900 dark:text-gray-100">{i18n.t("chat:tool_card_artifact_attempt_default")}</span>
      </div>
      {message ? (
        <div className="break-words text-sm text-text-secondary">{message}</div>
      ) : (
        <EmptyState>{pending ? i18n.t("chat:tool_card_artifact_waiting") : i18n.t("chat:tool_card_artifact_empty")}</EmptyState>
      )}
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {type ? <Row label={i18n.t("chat:tool_card_type")} value={type} /> : null}
        {workflowId ? (
          <div className="min-w-0">
            <div className="text-2xs font-semibold uppercase text-text-secondary">{i18n.t("chat:tool_card_workflow")}</div>
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
    label: i18n.t("chat:tool_card_artifact_example_image"),
    input: { workflow_id: 28622, job_id: 7705, type: "visual_review_screenshot" },
    parsedResult: [{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }]
  },
  {
    id: "not_found",
    label: i18n.t("chat:tool_card_artifact_example_missing"),
    input: { workflow_id: 28622, type: "missing_screenshot" },
    resultBody: "Error: no image artifact found for type missing_screenshot",
    resultError: true
  },
  {
    id: "pending",
    label: i18n.t("chat:tool_card_artifact_example_pending"),
    input: { workflow_id: 28622, type: "visual_review_screenshot" },
    parsedResult: null
  }
]

const readArtifactToolCard: ToolCardRenderer = {
  toolName: "read_artifact",
  collapsedSummary: readArtifactSummary,
  renderExpanded: renderReadArtifact
}

export default readArtifactToolCard

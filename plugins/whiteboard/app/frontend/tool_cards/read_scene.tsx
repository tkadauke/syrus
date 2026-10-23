import { useState } from "react"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Row } from "@app/routes/chat/toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary } from "@app/routes/chat/toolFailureSummaryCard"
import { parseReadSceneResult, sceneCountsSummary, t, WhiteboardScenePreview, type ReadSceneResult } from "../whiteboardToolCard"

// Plugin-owned tool card for read_scene (the pending-action tool-card work).
function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return toolFailureCollapsedSummary(context, failureConfig())
  const counts = parseReadSceneResult(context.parsedResult)
  return counts ? sceneCountsSummary(counts) : null
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError) return <ToolFailureSummaryCard config={failureConfig()} context={context} />
  const result = parseReadSceneResult(context.parsedResult)
  return result ? <ReadSceneCard result={result} /> : null
}

function ReadSceneCard({ result }: { result: ReadSceneResult }) {
  const [expanded, setExpanded] = useState(false)
  const visibleTexts = expanded ? result.texts : result.texts.slice(0, 3)
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_scene")}</Badge>
        {result.version != null ? <Badge>v{result.version}</Badge> : null}
      </div>
      {result.elementCount === 0 ? (
        <div className="text-sm text-text-secondary">{t("tool_empty_scene")}</div>
      ) : (
        <>
          <div className="flex flex-wrap gap-1.5" aria-label={t("tool_element_types")}>
            {result.typeCounts.map(({ type, count }) => (
              <Badge key={type}>
                {type} {count}
              </Badge>
            ))}
          </div>
          <WhiteboardScenePreview
            scene={result.scene}
            item={{
              title: t("tool_scene_preview"),
              subtitle: sceneCountsSummary(result),
              badge: t("tool_scene"),
              meta: [
                { label: t("tool_elements"), value: String(result.elementCount) },
                { label: t("tool_image_files"), value: String(result.fileCount) },
                { label: t("tool_version"), value: result.version != null ? String(result.version) : null }
              ]
            }}
          />
          {result.texts.length > 0 ? (
            <div className="min-w-0">
              <div className="mb-1 text-xs font-semibold uppercase text-text-muted">{t("tool_text_contents")}</div>
              <ul className="space-y-1">
                {visibleTexts.map((text, index) => (
                  <li className="break-words rounded bg-surface px-2 py-1 text-sm text-text-secondary" key={`${index}-${text.slice(0, 20)}`}>
                    {expanded || text.length <= 160 ? text : `${text.slice(0, 157)}…`}
                  </li>
                ))}
              </ul>
              {!expanded && (result.texts.length > 3 || result.texts.some((text) => text.length > 160)) ? (
                <button className="mt-2 text-xs font-semibold text-brand hover:underline" onClick={() => setExpanded(true)} type="button">
                  {t("tool_show_more")}
                </button>
              ) : null}
            </div>
          ) : null}
        </>
      )}
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("tool_elements")} value={String(result.elementCount)} />
        <Row label={t("tool_image_files")} value={String(result.fileCount)} />
      </dl>
    </CardShell>
  )
}

function failureConfig() {
  return {
    title: t("tool_read_scene"),
    attempted: () => t("tool_read_scene"),
    retrySafety: "safe" as const,
    recovery: t("tool_read_scene_recovery")
  }
}

function catalogElement(id: string, type: string, x: number, y: number, width: number, height: number) {
  return {
    id,
    type,
    x,
    y,
    width,
    height,
    angle: 0,
    strokeWidth: 2,
    strokeStyle: "solid",
    fillStyle: "solid",
    roughness: 1,
    opacity: 100,
    seed: id.length * 100,
    version: 1,
    versionNonce: id.length * 1000,
    index: null,
    isDeleted: false,
    groupIds: [],
    frameId: null,
    boundElements: null,
    roundness: null,
    updated: 1,
    link: null,
    locked: false
  }
}

const catalogRectangle = {
  ...catalogElement("box", "rectangle", 20, 20, 180, 100),
  backgroundColor: "#dbeafe",
  strokeColor: "#1d4ed8",
  boundElements: []
}
const catalogText = {
  ...catalogElement("label", "text", 48, 56, 124, 25),
  strokeColor: "#1e293b",
  backgroundColor: "transparent",
  text: "Launch plan",
  originalText: "Launch plan",
  fontSize: 20,
  fontFamily: 1,
  textAlign: "left",
  verticalAlign: "top",
  baseline: 20,
  lineHeight: 1.25,
  containerId: null,
  autoResize: true
}
const catalogArrow = {
  ...catalogElement("arrow", "arrow", 210, 70, 100, 0),
  strokeColor: "#475569",
  backgroundColor: "transparent",
  fillStyle: "hachure",
  points: [
    [0, 0],
    [100, 0]
  ],
  lastCommittedPoint: null,
  startBinding: null,
  endBinding: null,
  startArrowhead: null,
  endArrowhead: "arrow",
  elbowed: false
}
const catalogImage = {
  ...catalogElement("image", "image", 330, 20, 120, 100),
  strokeColor: "transparent",
  backgroundColor: "transparent",
  fileId: "image1",
  status: "saved",
  scale: [1, 1],
  crop: null
}

export const examples: ToolCardExample[] = [
  {
    id: "populated_scene",
    label: "Populated scene",
    parsedResult: {
      version: 4,
      elements: [catalogRectangle, catalogText, catalogArrow, catalogImage],
      appState: { viewBackgroundColor: "#ffffff" },
      files: {
        image1: {
          id: "image1",
          dataURL:
            "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='100'%3E%3Crect width='120' height='100' fill='%23dcfce7'/%3E%3C/svg%3E",
          mimeType: "image/svg+xml",
          created: 1,
          lastRetrieved: 1
        }
      }
    },
    sourceType: "generic"
  },
  { id: "empty_scene", label: "Empty scene", parsedResult: { version: 0, elements: [], appState: {}, files: {} }, sourceType: "generic" },
  { id: "error", label: "Error", resultBody: "Canvas unavailable", resultError: true, sourceType: "generic" }
]

const readSceneToolCard: ToolCardRenderer = {
  toolName: "read_scene",
  collapsedSummary,
  renderExpanded
}

export default readSceneToolCard

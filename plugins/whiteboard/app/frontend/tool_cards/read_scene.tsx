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

export const examples: ToolCardExample[] = [
  {
    id: "populated_scene",
    label: "Populated scene",
    parsedResult: {
      version: 4,
      elements: [
        { id: "box", type: "rectangle" },
        { id: "label", type: "text", text: "Launch plan" },
        { id: "arrow", type: "arrow" }
      ],
      appState: {},
      files: { image1: { id: "image1" } }
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

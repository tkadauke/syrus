import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import type { ChatWhiteboardScene } from "@app/api/chats"
import { Badge, CardShell, numberValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected } from "@app/routes/chat/toolFailureSummaryCard"
import { WhiteboardScenePreview } from "../whiteboardSnapshotPreview"
import { sceneCountsSummary, t, type SceneCounts } from "../whiteboardToolCard"

// Plugin-owned tool card for update_scene (the pending-action tool-card work). The tool's
// own result is just `{ replaced: true, version }` (see update_scene_tool.rb)
// -- the replacement element/file counts come from the tool call's own input
// instead, which update_scene_tool.rb requires (`elements`) or accepts
// optionally (`files`).
//
function sceneCounts(context: ToolCardContext): SceneCounts | null {
  const parsed = resultPayload(context.parsedResult)
  if (!isPlainObject(parsed) || parsed.replaced !== true) return null
  if (!isPlainObject(context.input) || !Array.isArray(context.input.elements)) return null

  const files = isPlainObject(context.input.files) ? context.input.files : {}

  return { elementCount: context.input.elements.length, fileCount: Object.keys(files).length, version: numberValue(parsed.version) }
}

function collapsedSummary(context: ToolCardContext) {
  if (toolFailureDetected(context)) return toolFailureCollapsedSummary(context, failureConfig)
  const counts = sceneCounts(context)
  if (counts) return `${t("tool_replaced_scene_summary", { summary: sceneCountsSummary(counts) })}${counts.version != null ? ` · v${counts.version}` : ""}`

  const parsed = resultPayload(context.parsedResult)
  const version = isPlainObject(parsed) && parsed.replaced === true ? numberValue(parsed.version) : null
  return isPlainObject(parsed) && parsed.replaced === true ? `${t("tool_replaced_scene")}${version != null ? ` · v${version}` : ""}` : null
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const counts = sceneCounts(context)
  if (!counts || !isPlainObject(context.input)) return null

  const input = context.input
  const appState = isPlainObject(input.appState) ? input.appState : {}
  const appStateKeys = Object.keys(appState)
  const shownKeys = appStateKeys.slice(0, 8)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_replaced_scene")}</Badge>
        {counts.version != null ? <Badge>v{counts.version}</Badge> : null}
      </div>
      <WhiteboardScenePreview
        item={{
          title: t("tool_replacement_preview"),
          subtitle: sceneCountsSummary(counts),
          badge: t("tool_scene"),
          meta: [
            { label: t("tool_elements"), value: String(counts.elementCount) },
            { label: t("tool_files"), value: String(counts.fileCount) },
            {
              label: t("tool_app_state_keys"),
              value: appStateKeys.length
                ? `${shownKeys.join(", ")}${appStateKeys.length > shownKeys.length ? `, +${appStateKeys.length - shownKeys.length}` : ""}`
                : t("tool_none")
            },
            { label: t("tool_version"), value: counts.version != null ? String(counts.version) : null }
          ]
        }}
        scene={{ elements: input.elements, appState, files: isPlainObject(input.files) ? input.files : {} } as Partial<ChatWhiteboardScene>}
      />
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("tool_elements")} value={String(counts.elementCount)} />
        <Row label={t("tool_files")} value={String(counts.fileCount)} />
      </dl>
      <div className="min-w-0">
        <SectionLabel>{t("tool_app_state_keys")}</SectionLabel>
        <div className="mt-1 flex min-w-0 flex-wrap gap-1">
          {shownKeys.length ? shownKeys.map((key) => <Badge key={key}>{key}</Badge>) : <span className="text-xs text-text-secondary">{t("tool_none")}</span>}
          {appStateKeys.length > shownKeys.length ? <Badge>+{appStateKeys.length - shownKeys.length}</Badge> : null}
        </div>
      </div>
    </CardShell>
  )
}

function resultPayload(value: unknown): unknown {
  if (!isPlainObject(value)) return value
  if (value.replaced === true) return value
  if (isPlainObject(value.structured_content)) return value.structured_content
  if (isPlainObject(value.structuredContent)) return value.structuredContent
  if (isPlainObject(value.result)) return resultPayload(value.result)
  return value
}

const failureConfig = {
  title: t("tool_replace_scene"),
  attempted: (context: ToolCardContext) => {
    const input = isPlainObject(context.input) ? context.input : {}
    const elements = Array.isArray(input.elements) ? input.elements.length : null
    return elements == null ? t("tool_replace_scene") : t("tool_replace_scene_attempt", { count: elements })
  },
  retrySafety: "caution" as const,
  recovery: t("tool_replace_scene_recovery")
}

export const examples: ToolCardExample[] = [
  {
    id: "replaced_scene",
    label: "Replaced scene",
    input: { elements: [{ id: "box", type: "rectangle", x: 0, y: 0, width: 120, height: 80 }], appState: { viewBackgroundColor: "#ffffff" }, files: {} },
    parsedResult: { replaced: true, version: 4 },
    sourceType: "generic"
  },
  {
    id: "empty_scene",
    label: "Empty scene",
    input: { elements: [], appState: {}, files: {} },
    parsedResult: { replaced: true, version: 5 },
    sourceType: "generic"
  },
  {
    id: "validation_error",
    label: "Validation error",
    input: { elements: [{ id: "bad" }] },
    resultBody: "element type is required",
    resultError: true,
    sourceType: "generic"
  }
]

const updateSceneToolCard: ToolCardRenderer = {
  toolName: "update_scene",
  collapsedSummary,
  renderExpanded
}

export default updateSceneToolCard

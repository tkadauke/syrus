import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { CompactActionCard, type CompactActionRow } from "@app/routes/chat/compactActionCard"
import { MediaPreviewShell, type MediaPreviewAction } from "@app/routes/chat/mediaPreviewShell"
import { humanizeToolName, ToolFailureSummaryCard, toolFailureCollapsedSummary, type ToolFailureConfig } from "@app/routes/chat/toolFailureSummaryCard"
import i18n from "i18next"
import { Badge, CardShell, displayValue, numberValue, Row } from "@app/routes/chat/toolCardUi"

// Shared presentation for the whiteboard plugin's chat tool cards (the pending-action tool-card work /
// Most drawing/move/delete tools return only `{ id, version }` --
// see plugins/whiteboard/app/services/whiteboard/*_tool.rb and
// Whiteboard::Canvas#mutate, which always merges `version` onto the block's
// result -- so one parser plus one card backs draw_shape, draw_text,
// draw_line, draw_arrow, draw_freedraw, draw_frame, draw_embed, draw_image,
// move_element, and delete_element; `tool_cards/<name>.tsx` files are thin
// re-exports that supply an action label and read the tool call's own input
// for a concise action summary.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason core keeps
// toolCardUi.tsx one directory up).
export type ElementResult = { id: string; version: number | null; labelId: string | null; fileId: string | null }

export function parseElementResult(value: unknown): ElementResult | null {
  if (isPlainObject(value) && isPlainObject(value.result)) value = value.result
  if (!isPlainObject(value)) return null

  const id = displayValue(value.id)
  if (!id) return null

  return { id, version: numberValue(value.version), labelId: displayValue(value.label_id), fileId: displayValue(value.file_id) }
}

// Small, deliberately generic set of input fields worth echoing across the
// whole draw/move family -- keeps every `tool_cards/draw_*.tsx` file a thin
// binding instead of a bespoke renderer per shape type.
const INPUT_FIELDS: { key: string; label: string }[] = [
  { key: "type", label: "tool_field_type" },
  { key: "x", label: "X" },
  { key: "y", label: "Y" },
  { key: "width", label: "tool_field_width" },
  { key: "height", label: "tool_field_height" },
  { key: "from_id", label: "tool_field_from" },
  { key: "to_id", label: "tool_field_to" },
  { key: "label", label: "tool_field_label" },
  { key: "content", label: "tool_field_content" },
  { key: "link", label: "tool_field_link" },
  { key: "name", label: "tool_field_name" },
  { key: "color", label: "tool_field_color" },
  { key: "stroke_width", label: "tool_field_stroke_width" },
  { key: "points", label: "tool_field_points" },
  { key: "start_arrowhead", label: "tool_field_start_arrowhead" },
  { key: "end_arrowhead", label: "tool_field_end_arrowhead" },
  { key: "font_size", label: "tool_field_font_size" },
  { key: "pressures", label: "tool_field_pressures" },
  { key: "simulate_pressure", label: "tool_field_simulate_pressure" },
  { key: "mime_type", label: "tool_field_mime_type" },
  { key: "file_id", label: "tool_field_file_id" }
]

export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`whiteboard:${key}`, options)
}

function inputDetails(input: Record<string, unknown> | undefined) {
  if (!isPlainObject(input)) return []

  return INPUT_FIELDS.flatMap(({ key, label }) => {
    const raw = input[key]
    const value = Array.isArray(raw)
      ? t("tool_points_count", { count: raw.length })
      : typeof raw === "boolean"
        ? t(raw ? "tool_yes" : "tool_no")
        : displayValue(raw)
    return value ? [{ key, label: label.length === 1 ? label : t(label), value }] : []
  })
}

export function elementActionSummary(action: string, result: ElementResult, input?: Record<string, unknown>): string {
  const type = isPlainObject(input) ? displayValue(input.type) : null
  return `${action}${type ? ` (${type})` : ""} · ${result.id}`
}

export function ElementActionCard({ action, result, input }: { action: string; result: ElementResult; input?: Record<string, unknown> }) {
  const details = inputDetails(input)
  const rows: CompactActionRow[] =
    details.length > 0
      ? [
          {
            label: t("tool_details"),
            value: (
              <>
                {details.map((detail) => (
                  <span className="inline-flex min-w-0 items-center gap-1" key={detail.key}>
                    <span className="text-text-subtle">{detail.label}:</span>
                    {detail.key === "color" ? (
                      <span
                        aria-label={detail.value}
                        className="h-3 w-3 shrink-0 rounded-full border border-border"
                        style={{ backgroundColor: detail.value }}
                      />
                    ) : null}
                    <span className="break-all font-mono">{detail.value}</span>
                  </span>
                ))}
              </>
            )
          }
        ]
      : []
  if (result.labelId) rows.push({ label: t("tool_field_label_id"), value: <span className="font-mono">{result.labelId}</span> })
  if (result.fileId) rows.push({ label: t("tool_field_file_id"), value: <span className="font-mono">{result.fileId}</span> })
  const link = isPlainObject(input) ? displayValue(input.link) : null
  if (link && /^https?:\/\//i.test(link))
    rows.push({
      label: t("tool_field_link"),
      value: (
        <a className="break-all text-brand hover:underline" href={link} rel="noreferrer" target="_blank">
          {link}
        </a>
      )
    })
  const dataUrl = isPlainObject(input) && typeof input.data_url === "string" && input.data_url.startsWith("data:image/") ? input.data_url : null
  const content = isPlainObject(input) ? displayValue(input.content) : null

  return (
    <CompactActionCard
      action={action}
      badges={result.version != null ? [`v${result.version}`] : []}
      entity={<span className="break-all font-mono font-semibold text-text-primary">{result.id}</span>}
      markdown={content ?? undefined}
      media={
        dataUrl
          ? {
              item: {
                title: result.fileId ?? t("tool_image"),
                src: dataUrl,
                alt: t("tool_image"),
                badge: isPlainObject(input) ? displayValue(input.mime_type) : null
              }
            }
          : undefined
      }
      rows={rows}
      tone="success"
    />
  )
}

export function makeElementCard(toolName: string, actionKey: string): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary(context) {
      const action = t(actionKey)
      const failureSummary = elementFailureSummary(context, action)
      if (failureSummary) return failureSummary
      const result = parseElementResult(context.parsedResult)
      if (!result) return context.parsedResult == null ? t("tool_pending_summary", { action }) : t("tool_missing_result_summary", { action })
      return elementActionSummary(action, result, isPlainObject(context.input) ? context.input : undefined)
    },
    renderExpanded(context) {
      const action = t(actionKey)
      if (context.resultError) return <ElementFailureCard action={action} context={context} />
      const result = parseElementResult(context.parsedResult)
      if (!result)
        return (
          <CompactActionCard
            action={action}
            rows={[{ label: t("tool_status"), value: t(context.parsedResult == null ? "tool_pending" : "tool_missing_result") }]}
            tone="info"
          />
        )
      return <ElementActionCard action={action} input={isPlainObject(context.input) ? context.input : undefined} result={result} />
    }
  }
}

export function elementFailureSummary(context: ToolCardContext, action: string) {
  return toolFailureCollapsedSummary(context, elementFailureConfig(context, action))
}

export function ElementFailureCard({ context, action }: { context: ToolCardContext; action: string }) {
  return <ToolFailureSummaryCard config={elementFailureConfig(context, action)} context={context} />
}

function elementFailureConfig(context: ToolCardContext, action: string): ToolFailureConfig {
  return {
    title: action,
    attempted: () => t("tool_attempted", { attempt: elementAttempt(context, action) }),
    retrySafety: "caution",
    recovery: t("tool_recovery_check_canvas")
  }
}

function elementAttempt(context: ToolCardContext, action: string) {
  const input = isPlainObject(context.input) ? context.input : {}
  const type = displayValue(input.type)
  const fromId = displayValue(input.from_id)
  const toId = displayValue(input.to_id)
  const id = displayValue(input.id) || displayValue(input.element_id)

  if (fromId && toId) return t("tool_attempt_from_to", { action, from: fromId, to: toId })
  if (id) return t("tool_attempt_id", { action, id })
  if (type) return t("tool_attempt_type", { action, type })
  return action || humanizeToolName(context.toolName)
}

// read_scene and update_scene both surface the whole scene rather than one
// element -- concise scene counts (elements/files/version) are the useful
// summary here, not a dump of every element.
export type SceneCounts = { elementCount: number; fileCount: number; version: number | null }

export function parseSceneCounts(value: unknown): SceneCounts | null {
  if (!isPlainObject(value) || !Array.isArray(value.elements)) return null

  const files = isPlainObject(value.files) ? value.files : {}

  return {
    elementCount: value.elements.length,
    fileCount: Object.keys(files).length,
    version: numberValue(value.version)
  }
}

export function sceneCountsSummary(counts: SceneCounts): string {
  const elements = t("tool_elements_summary", { count: counts.elementCount })
  return counts.fileCount > 0 ? t("tool_elements_files_summary", { elements, count: counts.fileCount }) : elements
}

export function SceneCountsCard({ counts, action }: { counts: SceneCounts; action: string }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{action}</Badge>
        {counts.version != null ? <Badge>v{counts.version}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("tool_elements")} value={String(counts.elementCount)} />
        <Row label={t("tool_files")} value={String(counts.fileCount)} />
      </dl>
    </CardShell>
  )
}

// save_canvas either records a snapshot or reports the canvas was empty.
export type SaveCanvasResult =
  { saved: true; snapshotId: string | null; name: string | null; elementCount: number | null } | { saved: false; reason: string | null }

export function parseSaveCanvasResult(value: unknown): SaveCanvasResult | null {
  if (!isPlainObject(value) || typeof value.saved !== "boolean") return null

  if (!value.saved) return { saved: false, reason: displayValue(value.reason) }

  return {
    saved: true,
    snapshotId: displayValue(value.snapshot_id),
    name: displayValue(value.name),
    elementCount: numberValue(value.element_count)
  }
}

export function SaveCanvasCard({ result }: { result: SaveCanvasResult }) {
  if (!result.saved) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <Badge>{t("tool_not_saved")}</Badge>
        </div>
        {result.reason ? <div className="text-gray-600 dark:text-gray-300">{result.reason}</div> : null}
      </CardShell>
    )
  }

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_saved_snapshot")}</Badge>
        {result.snapshotId ? <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{result.snapshotId}</span> : null}
      </div>
      {result.snapshotId ? (
        <MediaPreviewShell
          item={{
            title: result.name ?? `Snapshot #${result.snapshotId}`,
            subtitle: result.elementCount != null ? `${result.elementCount} element${result.elementCount === 1 ? "" : "s"}` : null,
            badge: "snapshot",
            fallbackLabel: "Whiteboard snapshot",
            actions: [{ label: "Copy ID", copyValue: result.snapshotId }],
            meta: [
              { label: "Snapshot ID", value: result.snapshotId, copyValue: result.snapshotId },
              { label: "Name", value: result.name },
              { label: "Elements", value: result.elementCount != null ? String(result.elementCount) : null }
            ]
          }}
          modalLabel="Whiteboard snapshot"
        />
      ) : (
        <>
          {result.name ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.name}</div> : null}
          {result.elementCount != null ? <Row label={t("tool_elements")} value={String(result.elementCount)} /> : null}
        </>
      )}
    </CardShell>
  )
}

// load_canvas either merges a snapshot into the live scene or replaces it
// (auto-saving the prior scene first).
export type LoadCanvasResult = {
  elementsAdded: number | null
  autoSavedSnapshotId: string | null
  snapshotId: string | null
  mode: string | null
}

export function parseLoadCanvasResult(value: unknown): LoadCanvasResult | null {
  if (!isPlainObject(value) || value.loaded !== true) return null

  return {
    elementsAdded: numberValue(value.elements_added),
    autoSavedSnapshotId: displayValue(value.auto_saved_snapshot_id),
    snapshotId: displayValue(value.snapshot_id),
    mode: displayValue(value.mode)
  }
}

export function LoadCanvasCard({ result }: { result: LoadCanvasResult }) {
  const actions: MediaPreviewAction[] = result.snapshotId ? [{ label: "Copy ID", copyValue: result.snapshotId }] : []
  if (result.autoSavedSnapshotId) actions.push({ label: "Copy auto-save", copyValue: result.autoSavedSnapshotId })

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_loaded_snapshot")}</Badge>
        {result.snapshotId ? <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{result.snapshotId}</span> : null}
        {result.mode ? <Badge>{result.mode}</Badge> : null}
      </div>
      {result.snapshotId ? (
        <MediaPreviewShell
          item={{
            title: `Snapshot #${result.snapshotId}`,
            subtitle: result.mode,
            badge: "snapshot",
            fallbackLabel: "Whiteboard snapshot",
            actions,
            meta: [
              { label: "Snapshot ID", value: result.snapshotId, copyValue: result.snapshotId },
              { label: "Mode", value: result.mode },
              { label: "Elements added", value: result.elementsAdded != null ? String(result.elementsAdded) : null },
              { label: "Auto-saved as", value: result.autoSavedSnapshotId, copyValue: result.autoSavedSnapshotId }
            ]
          }}
          modalLabel="Whiteboard snapshot"
        />
      ) : null}
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.elementsAdded != null ? <Row label={t("tool_elements_added")} value={String(result.elementsAdded)} /> : null}
        {result.autoSavedSnapshotId ? <Row label={t("tool_auto_saved_as")} value={`#${result.autoSavedSnapshotId}`} /> : null}
      </dl>
    </CardShell>
  )
}

// clear_canvas auto-snapshots the prior scene (when non-empty) before
// clearing it.
export type ClearCanvasResult = { snapshotId: string | null }

export function parseClearCanvasResult(value: unknown): ClearCanvasResult | null {
  if (!isPlainObject(value) || value.cleared !== true) return null

  return { snapshotId: displayValue(value.snapshot_id) }
}

export function ClearCanvasCard({ result }: { result: ClearCanvasResult }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_cleared_canvas")}</Badge>
      </div>
      {result.snapshotId ? (
        <Row label={t("tool_auto_saved_as")} value={`#${result.snapshotId}`} />
      ) : (
        <div className="text-gray-600 dark:text-gray-300">{t("tool_canvas_already_empty")}</div>
      )}
    </CardShell>
  )
}

import { isPlainObject } from "@app/pluginToolCards"
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
export type ElementResult = { id: string; version: number | null }

export function parseElementResult(value: unknown): ElementResult | null {
  if (!isPlainObject(value)) return null

  const id = displayValue(value.id)
  if (!id) return null

  return { id, version: numberValue(value.version) }
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
  { key: "name", label: "tool_field_name" }
]

export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`whiteboard:${key}`, options)
}

function inputRows(input: Record<string, unknown> | undefined) {
  if (!isPlainObject(input)) return []

  return INPUT_FIELDS.flatMap(({ key, label }) => {
    const value = displayValue(input[key])
    return value ? [{ key, label: label.length === 1 ? label : t(label), value }] : []
  })
}

export function elementActionSummary(action: string, result: ElementResult, input?: Record<string, unknown>): string {
  const type = isPlainObject(input) ? displayValue(input.type) : null
  return `${action}${type ? ` (${type})` : ""} · ${result.id}`
}

export function ElementActionCard({
  action,
  result,
  input
}: {
  action: string
  result: ElementResult
  input?: Record<string, unknown>
}) {
  const rows = inputRows(input)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{action}</Badge>
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{result.id}</span>
        {result.version != null ? <Badge>v{result.version}</Badge> : null}
      </div>
      {rows.length > 0 ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {rows.map((row) => (
            <Row key={row.key} label={row.label} value={row.value} />
          ))}
        </dl>
      ) : null}
    </CardShell>
  )
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
  | { saved: true; snapshotId: string | null; name: string | null; elementCount: number | null }
  | { saved: false; reason: string | null }

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
      {result.name ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{result.name}</div> : null}
      {result.elementCount != null ? <Row label={t("tool_elements")} value={String(result.elementCount)} /> : null}
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
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{t("tool_loaded_snapshot")}</Badge>
        {result.snapshotId ? <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{result.snapshotId}</span> : null}
        {result.mode ? <Badge>{result.mode}</Badge> : null}
      </div>
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

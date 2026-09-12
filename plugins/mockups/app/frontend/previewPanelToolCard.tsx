import { isPlainObject } from "@app/pluginToolCards"
import i18n from "i18next"
import { Badge, CardShell, displayValue, InternalLink, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

// Shared presentation for the mockups plugin's preview-panel chat tool cards
// (the pending-action tool-card work). show_preview and close_preview both return the same
// flat `panel_payload` hash (see
// plugins/mockups/app/services/mockups/tool_support.rb#panel_payload), so one
// parser plus one card backs both of them.
//
// Lives outside `tool_cards/` on purpose: core's pluginToolCards.tsx glob
// treats every non-test .tsx file under `tool_cards/` as a card module and
// would warn about the missing default export (same reason core keeps
// toolCardUi.tsx one directory up).
export type PreviewPanel = {
  panelId: string
  title: string | null
  state: string | null
  url: string | null
  fileCount: number | null
  versionId: string | null
  entryFile: string | null
  note: string | null
  mockupSlug: string | null
}

export function parsePreviewPanel(value: unknown): PreviewPanel | null {
  if (!isPlainObject(value)) return null

  const panelId = displayValue(value.panel_id)
  if (!panelId) return null

  return {
    panelId,
    title: displayValue(value.title),
    state: displayValue(value.state),
    url: displayValue(value.url),
    fileCount: numberValue(value.file_count),
    versionId: displayValue(value.version_id),
    entryFile: displayValue(value.entry_file),
    note: displayValue(value.note),
    mockupSlug: displayValue(value.mockup_slug)
  }
}

export function previewPanelSummary(panel: PreviewPanel): string {
  const label = panel.title || t("tool_panel_number", { id: panel.panelId })
  return panel.state ? `${label} (${panel.state})` : label
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mockups:${key}`, options)
}

export function PreviewPanelCard({ panel }: { panel: PreviewPanel }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{t("tool_panel_number", { id: panel.panelId })}</span>
        {panel.state ? <StatePill state={panel.state} /> : null}
        {panel.versionId ? <Badge>v{panel.versionId}</Badge> : null}
      </div>
      {panel.title ? <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{panel.title}</div> : null}
      {panel.entryFile || panel.fileCount != null ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {panel.entryFile ? <Row label={t("tool_entry_file")} value={panel.entryFile} /> : null}
          {panel.fileCount != null ? <Row label={t("tool_files")} value={String(panel.fileCount)} /> : null}
        </dl>
      ) : null}
      {panel.mockupSlug ? (
        <InternalLink href={`/mockups/${panel.mockupSlug}`}>{t("tool_open_mockup")}</InternalLink>
      ) : panel.url ? (
        <a
          className="block truncate font-mono text-xs text-brand hover:underline dark:text-brand-emphasis"
          href={panel.url}
          rel="noreferrer"
          target="_blank"
        >
          {panel.url}
        </a>
      ) : null}
      {panel.note ? <div className="text-gray-600 dark:text-gray-300">{panel.note}</div> : null}
    </CardShell>
  )
}

// write_preview_file and edit_preview_file both echo the panel id and file
// path they operated on, plus an optional replacement count for edits.
export type PreviewFileOp = { panelId: string; path: string; replacements: number | null }

export function parsePreviewFileOp(value: unknown): PreviewFileOp | null {
  if (!isPlainObject(value)) return null

  const panelId = displayValue(value.panel_id)
  const path = displayValue(value.path)
  if (!panelId || !path) return null

  return { panelId, path, replacements: numberValue(value.replacements) }
}

export function PreviewFileOpCard({ action, op }: { action: string; op: PreviewFileOp }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{action}</Badge>
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">{t("tool_panel_number", { id: op.panelId })}</span>
      </div>
      <Row label={t("tool_path")} value={op.path} />
      {op.replacements != null ? <Row label={t("tool_replacements")} value={String(op.replacements)} /> : null}
    </CardShell>
  )
}

import { MediaPreviewShell, type MediaPreviewAction } from "@app/components/media/MediaPreviewShell"
import { Badge, CardShell, displayValue, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"

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
  const label = panel.title || `Panel #${panel.panelId}`
  return panel.state ? `${label} (${panel.state})` : label
}

export function PreviewPanelCard({ panel }: { panel: PreviewPanel }) {
  const openHref = panel.mockupSlug ? `/mockups/${panel.mockupSlug}` : panel.url
  const actions: MediaPreviewAction[] = [{ label: "Copy panel ID", copyValue: panel.panelId }]
  if (openHref) actions.unshift({ label: panel.mockupSlug ? "Open mockup" : "Open preview", href: openHref })
  if (panel.url) actions.push({ label: "Copy URL", copyValue: panel.url })

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">Panel #{panel.panelId}</span>
        {panel.state ? <StatePill state={panel.state} /> : null}
        {panel.versionId ? <Badge>v{panel.versionId}</Badge> : null}
      </div>
      <MediaPreviewShell
        item={{
          title: panel.title ?? `Panel #${panel.panelId}`,
          subtitle: panel.entryFile ?? panel.url,
          badge: panel.state,
          fallbackLabel: "Preview panel",
          actions,
          meta: [
            { label: "Panel ID", value: panel.panelId, copyValue: panel.panelId },
            { label: "State", value: panel.state },
            { label: "Version", value: panel.versionId },
            { label: "Entry file", value: panel.entryFile },
            { label: "Files", value: panel.fileCount != null ? String(panel.fileCount) : null },
            { label: "URL", value: panel.url, copyValue: panel.url },
            { label: "Mockup", value: panel.mockupSlug, copyValue: panel.mockupSlug }
          ]
        }}
        modalLabel={panel.title ?? `Panel #${panel.panelId}`}
      />
      {panel.entryFile || panel.fileCount != null ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {panel.entryFile ? <Row label="Entry file" value={panel.entryFile} /> : null}
          {panel.fileCount != null ? <Row label="Files" value={String(panel.fileCount)} /> : null}
        </dl>
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
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">Panel #{op.panelId}</span>
      </div>
      <Row label="Path" value={op.path} />
      {op.replacements != null ? <Row label="Replacements" value={String(op.replacements)} /> : null}
    </CardShell>
  )
}

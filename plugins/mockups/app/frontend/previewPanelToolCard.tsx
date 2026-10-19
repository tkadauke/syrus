import type { ToolCardContext } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction } from "@app/routes/chat/mediaPreviewShell"
import { MarkdownPreview } from "@app/routes/chat/toolCardMarkdown"
import { ErrorCard } from "@app/routes/chat/chatHelperToolCard"
import { Badge, CardShell, displayValue, EntityReference, InternalLink, numberValue, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { isPlainObject } from "@app/toolCardParsing"
import i18n from "i18next"

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

export function previewPanelText(key: string, options?: Record<string, unknown>) {
  return i18n.t(`mockups:${key}`, options)
}
const t = previewPanelText

export function normalizedPreviewResult(value: unknown) {
  if (!isPlainObject(value)) return value
  if (value.structured_content != null) return value.structured_content
  const first = Array.isArray(value.content) ? value.content[0] : null
  if (!isPlainObject(first) || typeof first.text !== "string") return value
  try {
    return JSON.parse(first.text)
  } catch {
    return value
  }
}

export function parsePreviewPanel(value: unknown, input?: Record<string, unknown>): PreviewPanel | null {
  const normalized = normalizedPreviewResult(value)
  if (!isPlainObject(normalized)) return null
  const panelId = displayValue(normalized.panel_id)
  if (!panelId) return null
  return {
    panelId,
    title: displayValue(normalized.title) ?? displayValue(input?.title),
    state: displayValue(normalized.state),
    url: displayValue(normalized.url),
    fileCount: numberValue(normalized.file_count),
    versionId: displayValue(normalized.version_id),
    entryFile: displayValue(normalized.entry_file) ?? displayValue(input?.entry_file),
    note: displayValue(normalized.note),
    mockupSlug: displayValue(normalized.mockup_slug)
  }
}

function previewPanelState(panel: PreviewPanel) {
  if (panel.state && panel.state !== "open") return panel.state
  return panel.versionId || panel.mockupSlug ? t("tool_published") : t("tool_open_empty")
}

export function previewPanelSummary(panel: PreviewPanel): string {
  return `${panel.title || t("tool_panel_number", { id: panel.panelId })} (${previewPanelState(panel)})`
}

function PreviewIframe({ title, url, thumbnail = false }: { title: string; url: string; thumbnail?: boolean }) {
  return (
    <iframe
      className={
        thumbnail ? "pointer-events-none h-[400%] w-[400%] origin-top-left scale-25 border-0 bg-white" : "h-[min(70dvh,44rem)] w-full border-0 bg-white"
      }
      loading="lazy"
      sandbox="allow-forms allow-modals allow-scripts"
      src={url}
      title={thumbnail ? t("tool_thumbnail_title", { title }) : t("tool_preview_title", { title })}
    />
  )
}

export function PreviewPanelCard({ panel }: { panel: PreviewPanel }) {
  const title = panel.title ?? t("tool_panel_number", { id: panel.panelId })
  const published = Boolean(panel.versionId || panel.mockupSlug)
  const displayState = previewPanelState(panel)
  const openHref = panel.mockupSlug ? `/mockups/${panel.mockupSlug}` : panel.url
  const actions: MediaPreviewAction[] = [{ label: t("tool_copy_panel_id"), copyValue: panel.panelId }]
  if (openHref) actions.unshift({ label: panel.mockupSlug ? t("tool_open_mockup") : t("tool_open_preview"), href: openHref })
  if (panel.url) actions.push({ label: t("tool_copy_url"), copyValue: panel.url })
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference kind="preview_panel" label={t("tool_panel_number", { id: panel.panelId })} slug={panel.panelId} wrap="nowrap" />
        <StatePill state={displayState} tone={published ? "success" : "neutral"} />
        {panel.versionId ? <Badge>{t("tool_version_value", { id: panel.versionId })}</Badge> : null}
        {panel.mockupSlug ? <Badge>{panel.mockupSlug}</Badge> : null}
      </div>
      <div className="break-words text-sm font-semibold text-text-primary">{title}</div>
      {panel.url ? (
        <MediaPreviewShell
          item={{
            title,
            subtitle: panel.entryFile ?? panel.url,
            badge: displayState,
            actions,
            thumbnailChildren: <PreviewIframe thumbnail title={title} url={panel.url} />,
            previewChildren: <PreviewIframe title={title} url={panel.url} />,
            meta: [
              { label: t("tool_panel_id"), value: panel.panelId, copyValue: panel.panelId },
              { label: t("tool_state"), value: panel.state },
              { label: t("tool_version"), value: panel.versionId },
              { label: t("tool_entry_file"), value: panel.entryFile },
              { label: t("tool_files"), value: panel.fileCount != null ? String(panel.fileCount) : null },
              { label: t("tool_url"), value: panel.url, copyValue: panel.url },
              { label: t("tool_mockup"), value: panel.mockupSlug, copyValue: panel.mockupSlug }
            ]
          }}
          modalLabel={title}
          thumbnailClassName="w-full sm:w-72"
        />
      ) : null}
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        {panel.entryFile ? <Row label={t("tool_entry_file")} value={panel.entryFile} /> : null}
        {panel.fileCount != null ? <Row label={t("tool_files")} value={String(panel.fileCount)} /> : null}
      </div>
      {panel.mockupSlug ? <InternalLink href={`/mockups/${panel.mockupSlug}`}>{t("tool_open_mockup")}</InternalLink> : null}
      <MarkdownPreview
        emptyText={t("tool_no_note")}
        linkifySlugs
        linkifyUrls
        maxChars={640}
        maxLines={4}
        text={panel.note ?? ""}
        title={panel.note ? t("tool_note") : undefined}
      />
    </CardShell>
  )
}

export function previewError(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  const normalized = normalizedPreviewResult(context.parsedResult)
  if (isPlainObject(normalized)) {
    const message = displayValue(normalized.error) ?? displayValue(normalized.message)
    if (message) return message
  }
  return displayValue(context.resultBody)?.replace(/^Error:\s*/i, "") ?? t("tool_unknown_error")
}

export function PreviewErrorCard({ context, title }: { context: ToolCardContext; title: string }) {
  const message = previewError(context)
  return message ? <ErrorCard message={message} title={title} /> : null
}

export type PreviewFileOp = { panelId: string; path: string; replacements: number | null; size: number | null }
export function parsePreviewFileOp(value: unknown, input?: Record<string, unknown>): PreviewFileOp | null {
  const normalized = normalizedPreviewResult(value)
  if (!isPlainObject(normalized)) return null
  const panelId = displayValue(normalized.panel_id) ?? displayValue(input?.panel_id)
  const path = displayValue(normalized.path) ?? displayValue(input?.path)
  if (!panelId || !path) return null
  const content = typeof input?.content === "string" ? input.content : null
  return {
    panelId,
    path,
    replacements: numberValue(normalized.replacements),
    size: numberValue(normalized.size) ?? (content == null ? null : new Blob([content]).size)
  }
}

export function PreviewFileOpCard({ action, op }: { action: string; op: PreviewFileOp }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{action}</Badge>
        <EntityReference kind="preview_panel" label={t("tool_panel_number", { id: op.panelId })} slug={op.panelId} wrap="nowrap" />
      </div>
      <Row label={t("tool_path")} value={op.path} />
      {op.size != null ? <Row label={t("tool_size")} value={t("tool_bytes", { count: op.size })} /> : null}
      {op.replacements != null ? <Row label={t("tool_replacements")} value={String(op.replacements)} /> : null}
    </CardShell>
  )
}

import { useMemo, useState, type CSSProperties, type ReactNode } from "react"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { CopyIcon } from "../../components/CopyableSlug"
import { Modal } from "../../components/Modal"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import { useT } from "../../hooks/useT"
import { Markdown, renderLightMarkdown, type MarkdownLinkHandler } from "../../lib/Markdown"

const DEFAULT_MAX_LINES = 6
const APPROXIMATE_CHARS_PER_LINE = 160
const INLINE_MARKDOWN_CONSTRUCT = /`[^`\n]+`|\[[^\]\n]+\]\([^)\n]+\)|~~[^~\n]+~~|\*\*(?:(?!\*\*)[\s\S])+?\*\*|\*[^*\n]+\*/g
const MODAL_PANEL_CLASS = [
  "flex h-[100dvh] w-full min-w-0 flex-col overflow-hidden bg-surface",
  "shadow-[var(--shadow-panel)] sm:h-[min(82dvh,52rem)] sm:max-w-3xl sm:rounded-[var(--radius-panel)]"
].join(" ")
const CLOSE_BUTTON_CLASS = [
  "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-[var(--radius-control)]",
  "text-text-muted hover:bg-surface-raised hover:text-text-primary",
  "focus:outline-none focus:ring-2 focus:ring-brand"
].join(" ")

export type MarkdownPreviewProps = {
  text: string
  maxLines?: number
  maxChars?: number
  title?: string
  modalLabel?: string
  emptyState?: ReactNode
  linkifySlugs?: boolean
  linkifyUrls?: boolean
  onLinkClick?: MarkdownLinkHandler
}

type TruncatedMarkdown = { preview: string; truncated: boolean }

// Tool-card prose primitive: compact light markdown on the card, with the
// complete Markdown renderer available in a dialog only when content is cut.
export function MarkdownPreview({
  text,
  maxLines = DEFAULT_MAX_LINES,
  maxChars,
  title,
  modalLabel,
  emptyState,
  linkifySlugs = true,
  linkifyUrls = false,
  onLinkClick
}: MarkdownPreviewProps) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const { copied, copy } = useCopyToClipboard()
  const empty = !text.trim()
  const truncated = useMemo(() => truncateMarkdown(text, maxLines, maxChars), [text, maxChars, maxLines])

  if (empty)
    return <div className="rounded border border-dashed border-border px-3 py-2 text-xs text-text-muted">{emptyState ?? t("markdown_preview.empty")}</div>

  const lineClampStyle = {
    display: "-webkit-box",
    overflow: "hidden",
    WebkitBoxOrient: "vertical",
    WebkitLineClamp: Math.max(1, maxLines)
  } as CSSProperties
  const dialogLabel = modalLabel || title || t("show_more")

  return (
    <div className="min-w-0 max-w-full overflow-hidden">
      {title ? <div className="mb-1 break-words text-xs font-semibold text-text-primary">{title}</div> : null}
      <div className="break-words text-xs text-text-muted [overflow-wrap:anywhere]" data-testid="markdown-preview-content" style={lineClampStyle}>
        {renderLightMarkdown(truncated.preview, { linkifySlugs, linkifyUrls, onLinkClick })}
        {truncated.truncated ? "…" : null}
      </div>
      {truncated.truncated ? (
        <Button className="mt-2" onClick={() => setOpen(true)} size="sm" variant="secondary">
          {t("show_more")}
        </Button>
      ) : null}
      <Modal
        backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-black/50 p-0 sm:items-center sm:p-4"
        className={MODAL_PANEL_CLASS}
        label={dialogLabel}
        onClose={() => setOpen(false)}
        open={open}
      >
        <header className="flex shrink-0 items-center gap-3 border-b border-border px-4 py-3">
          <h2 className="min-w-0 flex-1 break-words text-sm font-semibold text-text-primary">{title || dialogLabel}</h2>
          <Button aria-label={t("markdown_preview.copy")} onClick={() => copy(text)} size="sm" variant="secondary">
            <CopyIcon className="h-3.5 w-3.5" />
            {copied ? t("copy.copied") : t("markdown_preview.copy")}
          </Button>
          <button aria-label={t("close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon />
          </button>
        </header>
        <div className="min-h-0 min-w-0 flex-1 overflow-y-auto overflow-x-hidden px-4 py-3">
          <Markdown
            className="min-w-0 break-words [overflow-wrap:anywhere] text-text-primary"
            linkifySlugs={linkifySlugs}
            linkifyUrls={linkifyUrls}
            onLinkClick={onLinkClick}
            text={text}
          />
        </div>
      </Modal>
    </div>
  )
}

export function truncateMarkdown(text: string, maxLines: number, maxChars?: number): TruncatedMarkdown {
  const normalized = text.replace(/\r\n?/g, "\n")
  const lines = normalized.split("\n")
  const safeMaxLines = Math.max(1, maxLines)
  const lineCutoff = lines.length > safeMaxLines ? lines.slice(0, safeMaxLines).join("\n").length : normalized.length
  const characterCutoff = safeMaxLines * APPROXIMATE_CHARS_PER_LINE
  const requestedCharacterCutoff = maxChars == null ? normalized.length : Math.max(1, maxChars)
  let cutoff = Math.min(lineCutoff, characterCutoff, requestedCharacterCutoff, normalized.length)

  if (cutoff === normalized.length) return { preview: normalized, truncated: false }

  for (const match of normalized.matchAll(INLINE_MARKDOWN_CONSTRUCT)) {
    const start = match.index
    const end = start + match[0].length
    if (start < cutoff && cutoff < end) {
      cutoff = start
      break
    }
  }

  const whitespace = normalized.slice(0, cutoff).search(/\s+\S*$/)
  if (whitespace > 0) cutoff = whitespace

  return { preview: normalized.slice(0, cutoff).trimEnd(), truncated: true }
}

import { useMemo, useState, type CSSProperties, type ReactNode } from "react"
import i18n from "i18next"
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

export type TextPreviewProps = MarkdownPreviewProps & { truncate?: TextTruncationMode; maxChars?: number }

export type TextTruncationMode = "head" | "tail" | "headTail"

export type TruncatedText = {
  preview: string
  truncated: boolean
  totalLines: number
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
  emptyState = null,
  linkifySlugs = true,
  linkifyUrls = false,
  onLinkClick
}: MarkdownPreviewProps) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const { copied, copy } = useCopyToClipboard()
  const empty = !text.trim()
  const truncated = useMemo(() => truncateMarkdown(text, maxLines, maxChars), [text, maxLines, maxChars])

  if (empty) return <>{emptyState}</>

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
          <button
            aria-label={t("copy.copy_to_clipboard", { slug: title || dialogLabel })}
            className={CLOSE_BUTTON_CLASS}
            onClick={() => copy(text)}
            title={copied ? t("copy.copied") : t("copy.copy", { slug: title || dialogLabel })}
            type="button"
          >
            <CopyIcon className={`h-4 w-4 ${copied ? "text-success-text" : ""}`} />
          </button>
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

// Tool-card raw-text primitive: preserve command output and logs on the card,
// while keeping the complete, copy-friendly text available in a dialog.
export function TextPreview({ text, maxLines = DEFAULT_MAX_LINES, maxChars, title, modalLabel, truncate = "head" }: TextPreviewProps) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const { copied, copy } = useCopyToClipboard()
  const empty = !text.trim()
  const truncated = useMemo(() => truncateTextLines(text, { mode: truncate, maxLines, maxChars }), [text, maxChars, maxLines, truncate])

  if (empty) return null

  const dialogLabel = modalLabel || title || t("show_more")

  return (
    <div className="min-w-0 max-w-full overflow-hidden">
      {title ? <div className="mb-1 break-words text-xs font-semibold text-text-primary">{title}</div> : null}
      <pre className="max-w-full whitespace-pre-wrap break-words font-mono text-xs text-text-muted [overflow-wrap:anywhere]" data-testid="text-preview-content">
        {truncated.preview}
      </pre>
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
          <button
            aria-label={t("copy.copy_to_clipboard", { slug: title || dialogLabel })}
            className={CLOSE_BUTTON_CLASS}
            onClick={() => copy(text)}
            title={copied ? t("copy.copied") : t("copy.copy", { slug: title || dialogLabel })}
            type="button"
          >
            <CopyIcon className={copied ? "text-success-text" : ""} />
          </button>
          <button aria-label={t("close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon />
          </button>
        </header>
        <div className="min-h-0 min-w-0 flex-1 overflow-auto px-4 py-3">
          <pre className="max-w-full whitespace-pre-wrap break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]">{text}</pre>
        </div>
      </Modal>
    </div>
  )
}

export function truncateText(text: string, maxLines: number): TruncatedMarkdown {
  const result = truncateTextLines(text, { mode: "head", maxLines })
  return { preview: result.preview, truncated: result.truncated }
}

export function truncateTextLines(
  text: string,
  { mode = "head", maxLines = DEFAULT_MAX_LINES, maxChars }: { mode?: TextTruncationMode; maxLines?: number; maxChars?: number } = {}
): TruncatedText {
  const normalized = text.replace(/\r\n?/g, "\n")
  const lines = normalized.split("\n")
  const safeMaxLines = Math.max(1, maxLines)
  const safeMaxChars = Math.max(1, maxChars ?? safeMaxLines * APPROXIMATE_CHARS_PER_LINE)
  const omittedLines = Math.max(0, lines.length - safeMaxLines)

  if (omittedLines === 0 && normalized.length <= safeMaxChars) {
    return { preview: normalized, truncated: false, totalLines: lines.length }
  }

  if (mode === "tail") {
    const tail = lines.slice(-safeMaxLines).join("\n")
    const characterClipped = tail.length > safeMaxChars
    const clipped = characterClipped ? tail.slice(-safeMaxChars) : tail
    const marker = characterClipped ? i18n.t("common:text_preview.earlier_text") : i18n.t("common:text_preview.earlier_lines", { count: omittedLines })
    return { preview: `${marker}\n${clipped}`, truncated: true, totalLines: lines.length }
  }

  if (mode === "headTail") {
    const headLines = Math.ceil(safeMaxLines / 2)
    const tailLines = Math.floor(safeMaxLines / 2)
    const head = lines.slice(0, headLines).join("\n")
    const tail = tailLines > 0 ? lines.slice(-tailLines).join("\n") : ""
    const headChars = Math.ceil(safeMaxChars / 2)
    const tailChars = Math.floor(safeMaxChars / 2)
    const characterClipped = head.length > headChars || tail.length > tailChars
    const clippedHead = head.slice(0, headChars)
    const clippedTail = tail.slice(-tailChars)
    const marker = characterClipped ? i18n.t("common:text_preview.text_omitted") : i18n.t("common:text_preview.lines_omitted", { count: omittedLines })
    return { preview: [clippedHead, marker, clippedTail].filter(Boolean).join("\n"), truncated: true, totalLines: lines.length }
  }

  const head = lines.slice(0, safeMaxLines).join("\n")
  const clipped = head.slice(0, safeMaxChars)

  return { preview: `${clipped}…`, truncated: true, totalLines: lines.length }
}

export function truncateMarkdown(text: string, maxLines: number, maxChars?: number): TruncatedMarkdown {
  const normalized = text.replace(/\r\n?/g, "\n")
  const lines = normalized.split("\n")
  const safeMaxLines = Math.max(1, maxLines)
  const lineCutoff = lines.length > safeMaxLines ? lines.slice(0, safeMaxLines).join("\n").length : normalized.length
  const characterCutoff = Math.max(1, maxChars ?? safeMaxLines * APPROXIMATE_CHARS_PER_LINE)
  let cutoff = Math.min(lineCutoff, characterCutoff, normalized.length)

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

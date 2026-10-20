import { useMemo, useState, type CSSProperties, type ReactNode } from "react"
import i18n from "i18next"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { CopyIcon } from "../../components/CopyableSlug"
import { Modal } from "../../components/Modal"
import { CodeSurface } from "../../components/ui"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import { useT } from "../../hooks/useT"
import type { HighlighterLanguageId } from "../../lib/highlighter"
import { Markdown, renderLightMarkdown, type MarkdownLinkHandler, type SlugTone } from "../../lib/Markdown"

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
  text: string | null | undefined
  className?: string
  copyLabel?: string
  emptyLabel?: string
  linkifySlugs?: boolean
  linkifyUrls?: boolean
  maxChars?: number
  maxLines?: number
  onLinkClick?: MarkdownLinkHandler
  title?: string
  modalLabel?: string
  emptyState?: ReactNode
  slugHrefFallbacks?: Record<string, string>
  slugTone?: SlugTone
}

export type TextPreviewProps = {
  fullText?: string
  text: string
  emptyLabel?: string
  modalText?: string
  lang?: HighlighterLanguageId | null
  maxChars?: number
  maxLines?: number
  modalLabel?: string
  title?: string
  truncate?: TextTruncationMode
  wrap?: boolean
}

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
  className,
  copyLabel,
  emptyLabel,
  emptyState,
  linkifySlugs = true,
  linkifyUrls = false,
  maxChars,
  maxLines = DEFAULT_MAX_LINES,
  modalLabel,
  onLinkClick,
  slugHrefFallbacks,
  slugTone,
  text,
  title
}: MarkdownPreviewProps) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  const [open, setOpen] = useState(false)
  const completeText = text ?? ""
  const normalized = completeText.trim()
  const truncated = useMemo(() => truncateMarkdown(normalized, maxLines, maxChars), [normalized, maxChars, maxLines])

  if (!normalized) {
    if (emptyState !== undefined) return <>{emptyState}</>
    return <p className="text-xs text-text-muted">{emptyLabel ?? t("markdown_preview.empty")}</p>
  }

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
      <div
        className={["break-words text-xs text-text-muted [overflow-wrap:anywhere]", className].filter(Boolean).join(" ")}
        data-testid="markdown-preview-content"
        style={lineClampStyle}
      >
        {renderLightMarkdown(truncated.preview, { linkifySlugs, linkifyUrls, onLinkClick, slugHrefFallbacks, slugTone })}
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
        <header className="flex shrink-0 flex-wrap items-center gap-2 border-b border-border px-4 py-3 sm:flex-nowrap">
          <h2 className="min-w-0 flex-1 break-words text-sm font-semibold text-text-primary">{title || dialogLabel}</h2>
          <button
            aria-label={copyLabel ?? t("copy.copy_to_clipboard", { slug: title || dialogLabel })}
            className={CLOSE_BUTTON_CLASS}
            onClick={() => copy(completeText)}
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
            slugHrefFallbacks={slugHrefFallbacks}
            slugTone={slugTone}
            text={completeText}
          />
        </div>
      </Modal>
    </div>
  )
}

// Tool-card raw-text primitive: preserve command output and logs on the card,
// while keeping the complete, copy-friendly text available in a dialog.
export function TextPreview({
  fullText,
  text,
  emptyLabel,
  modalText,
  lang = null,
  maxLines = DEFAULT_MAX_LINES,
  maxChars,
  title,
  modalLabel,
  truncate = "head",
  wrap = true
}: TextPreviewProps) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const { copied, copy } = useCopyToClipboard()
  const empty = !text.trim()
  const truncated = useMemo(() => truncateTextLines(text, { mode: truncate, maxLines, maxChars }), [text, maxChars, maxLines, truncate])

  if (empty) return emptyLabel ? <div className="text-xs italic text-text-muted">{emptyLabel}</div> : null

  const dialogLabel = modalLabel || title || t("show_more")
  const completeText = modalText ?? fullText ?? text
  const showModal = truncated.truncated || modalText != null || completeText !== text

  return (
    <div className="min-w-0 max-w-full overflow-hidden">
      {title ? <div className="mb-1 break-words text-xs font-semibold text-text-primary">{title}</div> : null}
      <CodeSurface
        className={
          wrap
            ? "max-w-full whitespace-pre-wrap break-words font-mono text-xs text-text-muted [overflow-wrap:anywhere]"
            : "max-w-full overflow-x-auto whitespace-pre font-mono text-xs text-text-muted"
        }
        code={truncated.preview}
        data-testid="text-preview-content"
        lang={lang}
        maxHeightClassName="max-h-72"
      />
      {showModal ? (
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
            onClick={() => copy(completeText)}
            title={copied ? t("copy.copied") : t("copy.copy", { slug: title || dialogLabel })}
            type="button"
          >
            <CopyIcon className={copied ? "text-success-text" : ""} />
          </button>
          <button aria-label={t("close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon />
          </button>
        </header>
        <div className="min-h-0 min-w-0 flex-1 overflow-auto p-4">
          <CodeSurface
            className={
              wrap
                ? "max-w-full whitespace-pre-wrap break-words font-mono text-xs text-text-primary [overflow-wrap:anywhere]"
                : "max-w-full overflow-x-auto whitespace-pre font-mono text-xs text-text-primary"
            }
            code={completeText}
            lang={lang}
            maxHeightClassName="max-h-none"
          >
            {lang ? undefined : <code className={wrap ? "break-words [overflow-wrap:anywhere]" : "whitespace-pre"}>{completeText}</code>}
          </CodeSurface>
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

  if (maxChars == null) {
    const whitespace = normalized.slice(0, cutoff).search(/\s+\S*$/)
    if (whitespace > 0) cutoff = whitespace
  }

  return { preview: normalized.slice(0, cutoff).trimEnd(), truncated: true }
}

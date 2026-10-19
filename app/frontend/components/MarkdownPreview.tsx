import { useState, type MouseEvent } from "react"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { useT } from "../hooks/useT"
import { Markdown, type MarkdownLinkHandler } from "../lib/Markdown"
import { Button } from "./Button"
import { CloseIcon } from "./CloseIcon"
import { Modal } from "./Modal"

const PREVIEW_CLASS = "min-w-0 break-words [overflow-wrap:anywhere] text-sm text-text-secondary"
const MODAL_CLASS =
  "flex max-h-[min(85dvh,48rem)] w-full max-w-3xl flex-col overflow-hidden rounded-[var(--radius-panel)] bg-surface shadow-[var(--shadow-panel)]"
const CLOSE_BUTTON_CLASS =
  "inline-flex min-h-11 min-w-11 items-center justify-center rounded-[var(--radius-control)] text-text-muted hover:bg-surface-raised hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand sm:min-h-8 sm:min-w-8"

export type MarkdownPreviewProps = {
  className?: string
  emptyLabel?: string
  linkifySlugs?: boolean
  linkifyUrls?: boolean
  maxChars?: number
  onLinkClick?: MarkdownLinkHandler
  text: string | null | undefined
}

export function MarkdownPreview({ className, emptyLabel, linkifySlugs = true, linkifyUrls = false, maxChars = 600, onLinkClick, text }: MarkdownPreviewProps) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  const [open, setOpen] = useState(false)
  const normalized = text?.trim() ?? ""

  if (!normalized) {
    return <p className="text-sm text-text-muted">{emptyLabel ?? t("markdown_preview.empty")}</p>
  }

  const truncated = normalized.length > maxChars
  const preview = truncated ? `${normalized.slice(0, maxChars).trimEnd()}…` : normalized

  function preserveModalLinks(href: string, event: MouseEvent<HTMLAnchorElement>) {
    onLinkClick?.(href, event)
  }

  return (
    <>
      <div className={[PREVIEW_CLASS, className].filter(Boolean).join(" ")}>
        <Markdown linkifySlugs={linkifySlugs} linkifyUrls={linkifyUrls} onLinkClick={onLinkClick} text={preview} />
      </div>
      {truncated ? (
        <Button className="mt-1 min-h-11 sm:min-h-0" onClick={() => setOpen(true)} size="sm" variant="secondary">
          {t("show_more")}
        </Button>
      ) : null}
      <Modal className={MODAL_CLASS} label={t("markdown_preview.dialog_label")} onClose={() => setOpen(false)} open={open}>
        <header className="flex shrink-0 items-center gap-2 border-b border-border px-4 py-3">
          <h2 className="min-w-0 flex-1 text-sm font-semibold text-text-primary">{t("markdown_preview.title")}</h2>
          <Button className="min-h-11 sm:min-h-0" onClick={() => copy(normalized)} size="sm" variant="secondary">
            {copied ? t("copy.copied") : t("markdown_preview.copy")}
          </Button>
          <button aria-label={t("markdown_preview.close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="min-h-0 flex-1 overflow-auto px-4 py-3">
          <Markdown
            className="break-words [overflow-wrap:anywhere] text-text-secondary"
            linkifySlugs={linkifySlugs}
            linkifyUrls={linkifyUrls}
            onLinkClick={preserveModalLinks}
            text={normalized}
          />
        </div>
      </Modal>
    </>
  )
}

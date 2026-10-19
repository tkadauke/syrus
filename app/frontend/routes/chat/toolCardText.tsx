import { useState } from "react"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Modal } from "../../components/Modal"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import { useT } from "../../hooks/useT"

const MODAL_PANEL_CLASS = [
  "flex h-[100dvh] w-full min-w-0 flex-col overflow-hidden bg-surface",
  "shadow-[var(--shadow-panel)] sm:h-[min(82dvh,52rem)] sm:max-w-3xl sm:rounded-[var(--radius-panel)]"
].join(" ")
const CLOSE_BUTTON_CLASS = [
  "inline-flex h-11 w-11 shrink-0 items-center justify-center rounded-[var(--radius-control)]",
  "text-text-muted hover:bg-surface-raised"
].join(" ")

export function TextPreview({
  text,
  title,
  maxChars = 960,
  emptyLabel = "No content."
}: {
  text: string
  title: string
  maxChars?: number
  emptyLabel?: string
}) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const { copied, copy } = useCopyToClipboard()
  if (!text.trim()) return <div className="text-xs italic text-text-muted">{emptyLabel}</div>

  const truncated = text.length > maxChars
  const preview = truncated ? text.slice(0, maxChars).trimEnd() : text
  return (
    <div className="min-w-0 max-w-full">
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">
        {preview}
        {truncated ? "…" : ""}
      </pre>
      {truncated ? (
        <Button className="mt-2" onClick={() => setOpen(true)} size="sm" variant="secondary">
          {t("show_more")}
        </Button>
      ) : null}
      <Modal className={MODAL_PANEL_CLASS} label={title} onClose={() => setOpen(false)} open={open}>
        <header className="flex shrink-0 items-center gap-3 border-b border-border px-4 py-3">
          <h2 className="min-w-0 flex-1 break-words text-sm font-semibold text-text-primary">{title}</h2>
          <Button onClick={() => copy(text)} size="sm" variant="secondary">
            {copied ? t("copy.copied") : t("copy.copy", { slug: title })}
          </Button>
          <button aria-label={t("close")} className={CLOSE_BUTTON_CLASS} onClick={() => setOpen(false)} type="button">
            <CloseIcon />
          </button>
        </header>
        <pre className="min-h-0 min-w-0 flex-1 overflow-auto whitespace-pre-wrap break-words px-4 py-3 font-mono text-xs text-text-primary">{text}</pre>
      </Modal>
    </div>
  )
}

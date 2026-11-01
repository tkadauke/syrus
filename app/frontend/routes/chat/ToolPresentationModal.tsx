import { useEffect, useState } from "react"
import { buttonClasses } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Modal } from "../../components/Modal"
import { useT } from "../../hooks/useT"
import { withRoutePrefix } from "../../lib/routing"

type Presentation = { chat_session_id?: unknown; title?: unknown; path?: unknown }
const BACKDROP_CLASSES = [
  "fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch",
  "bg-text-primary/40 p-0 sm:items-center sm:justify-center sm:p-4"
].join(" ")
const MODAL_CLASSES = [
  "flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-surface-raised shadow-2xl",
  "sm:h-[94dvh] sm:w-[96dvw] sm:rounded-lg"
].join(" ")

export function ToolPresentationModal({ chatId, prefix }: { chatId: string; prefix: string }) {
  const { t } = useT("chat")
  const [presentation, setPresentation] = useState<{ title: string; path: string } | null>(null)

  useEffect(() => {
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<Presentation>).detail
      if (String(detail?.chat_session_id) !== String(chatId) || typeof detail?.title !== "string" || typeof detail?.path !== "string") return
      setPresentation({ title: detail.title, path: detail.path })
    }
    window.addEventListener("syrus:tool-presentation", listener)
    return () => window.removeEventListener("syrus:tool-presentation", listener)
  }, [chatId])

  const path = presentation ? withRoutePrefix(presentation.path, prefix) : null
  return (
    <Modal
      backdropClassName={BACKDROP_CLASSES}
      className={MODAL_CLASSES}
      label={presentation?.title || t("tool_presentation_title")}
      onClose={() => setPresentation(null)}
      open={path != null}
    >
      <header className="flex shrink-0 items-center gap-3 border-b border-border bg-surface-raised px-4 py-3">
        <h2 className="min-w-0 flex-1 truncate text-sm font-semibold text-text-primary">{presentation?.title}</h2>
        {path ? (
          <a className={buttonClasses("secondary", "sm")} href={path}>
            {t("tool_presentation_open_full_page")}
          </a>
        ) : null}
        <button
          aria-label={t("tool_presentation_close")}
          className="rounded p-1.5 text-text-secondary hover:bg-surface-subtle focus-visible:ring-2 focus-visible:ring-brand"
          onClick={() => setPresentation(null)}
          type="button"
        >
          <CloseIcon className="h-4 w-4" />
        </button>
      </header>
      <div className="min-h-0 flex-1">
        <iframe className="h-full w-full border-0" src={path || undefined} title={presentation?.title} />
      </div>
    </Modal>
  )
}

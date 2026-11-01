import { useEffect, useState } from "react"
import { buttonClasses } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Modal } from "../../components/Modal"
import { useT } from "../../hooks/useT"
import { withRoutePrefix } from "../../lib/routing"

type Presentation = { chat_session_id?: unknown; title?: unknown; title_i18n_key?: unknown; path?: unknown }
const BACKDROP_CLASSES = [
  "fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch",
  "bg-text-primary/40 p-0 sm:items-center sm:justify-center sm:p-4"
].join(" ")
const MODAL_CLASSES = ["flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-surface-raised shadow-2xl", "sm:h-[94dvh] sm:w-[96dvw] sm:rounded-lg"].join(" ")
const HEADER_CLASSES = [
  "flex shrink-0 flex-wrap items-center gap-2 border-b border-border bg-surface-raised px-3 py-2",
  "sm:flex-nowrap sm:gap-3 sm:px-4 sm:py-3"
].join(" ")
const CLOSE_BUTTON_CLASSES = [
  "ml-auto shrink-0 rounded p-1.5 text-text-secondary hover:bg-surface-subtle",
  "focus-visible:ring-2 focus-visible:ring-brand sm:ml-0"
].join(" ")

function embeddedPath(path: string) {
  const url = new URL(path, window.location.origin)
  url.searchParams.set("syrus_presentation", "embedded")
  return `${url.pathname}?${url.searchParams.toString()}`
}

export function ToolPresentationModal({ chatId, prefix }: { chatId: string; prefix: string }) {
  const { t } = useT("chat")
  const [presentation, setPresentation] = useState<{ title: string; path: string } | null>(null)

  useEffect(() => {
    const listener = (event: Event) => {
      const detail = (event as CustomEvent<Presentation>).detail
      if (String(detail?.chat_session_id) !== String(chatId) || typeof detail?.path !== "string") return
      const title = typeof detail.title_i18n_key === "string" ? t(detail.title_i18n_key) : detail.title
      if (typeof title !== "string") return
      setPresentation({ title, path: detail.path })
    }
    window.addEventListener("syrus:tool-presentation", listener)
    return () => window.removeEventListener("syrus:tool-presentation", listener)
  }, [chatId, t])

  const path = presentation ? withRoutePrefix(presentation.path, prefix) : null
  const iframePath = path ? embeddedPath(path) : null
  return (
    <Modal
      backdropClassName={BACKDROP_CLASSES}
      className={MODAL_CLASSES}
      label={presentation?.title || t("tool_presentation_title")}
      onClose={() => setPresentation(null)}
      open={path != null}
    >
      <header className={HEADER_CLASSES}>
        <h2 className="min-w-0 basis-full truncate text-sm font-semibold text-text-primary sm:flex-1 sm:basis-auto">{presentation?.title}</h2>
        <div className="flex w-full min-w-0 items-center gap-2 sm:w-auto sm:shrink-0">
          {path ? (
            <button
              className={buttonClasses("secondary", "sm")}
              onClick={() => void navigator.clipboard.writeText(new URL(path, window.location.origin).toString())}
              type="button"
            >
              {t("tool_presentation_copy_link")}
            </button>
          ) : null}
          {path ? (
            <a className={`${buttonClasses("secondary", "sm")} min-w-0`} href={path}>
              <span className="truncate">{t("tool_presentation_open_full_page")}</span>
            </a>
          ) : null}
          <button aria-label={t("tool_presentation_close")} className={CLOSE_BUTTON_CLASSES} onClick={() => setPresentation(null)} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
      </header>
      <div className="min-h-0 flex-1">
        <iframe className="h-full w-full border-0" src={iframePath || undefined} title={presentation?.title} />
      </div>
    </Modal>
  )
}

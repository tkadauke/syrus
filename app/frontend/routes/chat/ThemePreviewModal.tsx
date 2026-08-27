import { useEffect, useState } from "react"
import { buttonClasses } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Modal } from "../../components/Modal"
import { useT } from "../../hooks/useT"
import { withRoutePrefix } from "../../lib/routing"

type ThemePreviewEventDetail = {
  chat_session_id?: unknown
  theme_id?: unknown
  path?: unknown
}

// Listens for the "syrus:theme-preview" window CustomEvent the preview_theme
// chat MCP tool triggers (via appEvents.ts's chatThemePreviewPayload), and
// pops the Design System page open in a Modal so the user can see the
// agent's draft theme against real components -- there is no existing
// "agent opens a popup in the user's chat UI" primitive, so this follows the
// same CustomEvent hand-off pattern as syrus:job-status-changed and
// syrus:video-walkthrough.
export function ThemePreviewModal({ chatId, prefix }: { chatId: string; prefix: string }) {
  const { t } = useT("chat")
  const [previewPath, setPreviewPath] = useState<string | null>(null)

  useEffect(() => {
    function handleThemePreview(event: Event) {
      const detail = (event as CustomEvent<ThemePreviewEventDetail>).detail
      if (String(detail?.chat_session_id) !== String(chatId)) return
      if (typeof detail?.path !== "string") return

      setPreviewPath(detail.path)
    }

    window.addEventListener("syrus:theme-preview", handleThemePreview)
    return () => window.removeEventListener("syrus:theme-preview", handleThemePreview)
  }, [chatId])

  const previewUrl = previewPath ? withRoutePrefix(previewPath, prefix) : null

  return (
    <Modal
      backdropClassName="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/40 p-0 sm:items-center sm:p-4"
      className="flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-white shadow-2xl sm:h-[min(90dvh,64rem)] sm:w-[min(94dvw,80rem)] sm:rounded-lg dark:bg-gray-950"
      label={t("theme_preview_title")}
      onClose={() => setPreviewPath(null)}
      open={previewUrl != null}
    >
      <header className="sticky top-0 z-10 flex shrink-0 items-center gap-3 border-b border-gray-200 bg-white px-4 py-3 dark:border-gray-800 dark:bg-gray-950">
        <h2 className="min-w-0 flex-1 truncate text-sm font-semibold text-gray-900 dark:text-gray-100">{t("theme_preview_title")}</h2>
        {previewUrl ? (
          <a className={buttonClasses("secondary", "sm")} href={previewUrl} rel="noreferrer" target="_blank">{t("theme_preview_open_in_new_tab")}</a>
        ) : null}
        <button aria-label={t("theme_preview_close")} className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-300 dark:hover:bg-gray-900 dark:hover:text-white" onClick={() => setPreviewPath(null)} type="button">
          <CloseIcon className="h-4 w-4" />
        </button>
      </header>
      <div className="min-h-0 flex-1 bg-gray-50 dark:bg-gray-900">
        {previewUrl ? <iframe className="h-full w-full border-0" src={previewUrl} title={t("theme_preview_title")} /> : null}
      </div>
    </Modal>
  )
}

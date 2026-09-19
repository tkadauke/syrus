import { useEffect, type ReactNode } from "react"
import { useT } from "../hooks/useT"
import { DismissButton } from "./DismissButton"
import { NOTICE_AUTO_DISMISS_DELAY_MS, noticeSurfaceClass } from "./noticeStyles"

export function NoticeToast({ children, message, onDismiss, persistent }: { children?: ReactNode; message?: ReactNode | null; onDismiss: () => void; persistent?: boolean }) {
  const { t } = useT("common")
  const content = children ?? message
  useEffect(() => {
    if (!content || persistent) return

    const timeout = window.setTimeout(onDismiss, NOTICE_AUTO_DISMISS_DELAY_MS)
    return () => window.clearTimeout(timeout)
  }, [content, onDismiss, persistent])

  if (!content) return null

  return (
    <div aria-live="polite" className="fixed right-4 top-[68px] z-50 max-w-sm sm:right-6 lg:top-4" role="status">
      <div className={noticeSurfaceClass("flex items-start gap-3")}>
        <div className="min-w-0 flex-1">{content}</div>
        <DismissButton label={t("notice_toast.dismiss")} onClick={onDismiss} />
      </div>
    </div>
  )
}

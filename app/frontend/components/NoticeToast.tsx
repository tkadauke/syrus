import { useEffect, type ReactNode } from "react"
import { useT } from "../hooks/useT"
import { DismissButton } from "./DismissButton"
import { NOTICE_AUTO_DISMISS_DELAY_MS, NOTICE_TOAST_VIEWPORT_CLASS, noticeSurfaceClass } from "./noticeStyles"

export type NoticeToastTone = "notice" | "error"

function noticeToneClass(tone: NoticeToastTone) {
  if (tone === "error") return "border-red-300 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-100"
  return ""
}

export function NoticeToast({ children, message, onDismiss, persistent, tone = "notice" }: { children?: ReactNode; message?: ReactNode | null; onDismiss: () => void; persistent?: boolean; tone?: NoticeToastTone }) {
  const { t } = useT("common")
  const content = children ?? message
  useEffect(() => {
    if (!content || persistent) return

    const timeout = window.setTimeout(onDismiss, NOTICE_AUTO_DISMISS_DELAY_MS)
    return () => window.clearTimeout(timeout)
  }, [content, onDismiss, persistent])

  if (!content) return null

  return (
    <div aria-live={tone === "error" ? "assertive" : "polite"} className={NOTICE_TOAST_VIEWPORT_CLASS} role={tone === "error" ? "alert" : "status"}>
      <div className={noticeSurfaceClass(["flex items-start gap-3", noticeToneClass(tone)].filter(Boolean).join(" "))}>
        <div className="min-w-0 flex-1">{content}</div>
        <DismissButton label={t("notice_toast.dismiss")} onClick={onDismiss} />
      </div>
    </div>
  )
}

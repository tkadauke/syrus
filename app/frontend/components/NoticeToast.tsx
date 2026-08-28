import { useEffect, type ReactNode } from "react"
import { useT } from "../hooks/useT"
import { DismissButton } from "./DismissButton"

const AUTO_DISMISS_DELAY_MS = 3_000

export function NoticeToast({ children, message, onDismiss, persistent }: { children?: ReactNode; message?: ReactNode | null; onDismiss: () => void; persistent?: boolean }) {
  const { t } = useT("common")
  const content = children ?? message
  useEffect(() => {
    if (!content || persistent) return

    const timeout = window.setTimeout(onDismiss, AUTO_DISMISS_DELAY_MS)
    return () => window.clearTimeout(timeout)
  }, [content, onDismiss, persistent])

  if (!content) return null

  return (
    <div aria-live="polite" className="fixed right-4 top-[68px] z-50 max-w-sm sm:right-6 lg:top-4" role="status">
      <div className="flex items-start gap-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 px-4 py-3 text-sm text-gray-800 dark:text-gray-200 shadow-lg">
        <div className="min-w-0 flex-1">{content}</div>
        <DismissButton label={t("notice_toast.dismiss")} onClick={onDismiss} />
      </div>
    </div>
  )
}

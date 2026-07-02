import { useEffect, type ReactNode } from "react"
import { CloseIcon } from "./CloseIcon"

const AUTO_DISMISS_DELAY_MS = 10_000

export function NoticeToast({ children, message, onDismiss, persistent }: { children?: ReactNode; message?: ReactNode | null; onDismiss: () => void; persistent?: boolean }) {
  const content = children ?? message
  useEffect(() => {
    if (!content || persistent) return

    const timeout = window.setTimeout(onDismiss, AUTO_DISMISS_DELAY_MS)
    return () => window.clearTimeout(timeout)
  }, [content, onDismiss, persistent])

  if (!content) return null

  return (
    <div aria-live="polite" className="fixed right-4 top-20 z-50 max-w-sm sm:right-6" role="status">
      <div className="flex items-start gap-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 px-4 py-3 text-sm text-gray-800 dark:text-gray-200 shadow-lg">
        <div className="min-w-0 flex-1">{content}</div>
        <button
          aria-label="Dismiss notification"
          className="-mr-1 inline-flex h-6 w-6 items-center justify-center rounded text-gray-400 dark:text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300"
          onClick={onDismiss}
          type="button"
        >
          <CloseIcon />
        </button>
      </div>
    </div>
  )
}

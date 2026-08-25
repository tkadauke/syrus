import { useRef } from "react"
import { Modal } from "./Modal"

export interface ConfirmDialogProps {
  open: boolean
  message: string
  confirmLabel?: string
  cancelLabel?: string
  destructive?: boolean
  onConfirm: () => void
  onCancel: () => void
}

export function ConfirmDialog({
  open,
  message,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  destructive = false,
  onConfirm,
  onCancel
}: ConfirmDialogProps) {
  const confirmRef = useRef<HTMLButtonElement>(null)

  return (
    <Modal initialFocusRef={confirmRef} label={message} onClose={onCancel} open={open}>
      <p className="text-sm text-gray-700 dark:text-gray-300">{message}</p>
      <div className="mt-4 flex justify-end gap-2">
        <button
          className="rounded border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
          onClick={onCancel}
          type="button"
        >
          {cancelLabel}
        </button>
        <button
          className={
            destructive
              ? "rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700"
              : "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700"
          }
          onClick={onConfirm}
          ref={confirmRef}
          type="button"
        >
          {confirmLabel}
        </button>
      </div>
    </Modal>
  )
}

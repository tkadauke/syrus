import { useRef } from "react"
import { useT } from "../hooks/useT"
import { Button } from "./Button"
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

export function ConfirmDialog({ open, message, confirmLabel, cancelLabel, destructive = false, onConfirm, onCancel }: ConfirmDialogProps) {
  const { t } = useT("common")
  const confirmRef = useRef<HTMLButtonElement>(null)

  return (
    <Modal initialFocusRef={confirmRef} label={message} onClose={onCancel} open={open}>
      <p className="text-sm text-gray-700 dark:text-gray-300">{message}</p>
      <div className="mt-4 flex justify-end gap-2">
        <Button onClick={onCancel} variant="secondary">
          {cancelLabel ?? t("cancel")}
        </Button>
        <Button onClick={onConfirm} ref={confirmRef} variant={destructive ? "danger" : "primary"}>
          {confirmLabel ?? t("confirm")}
        </Button>
      </div>
    </Modal>
  )
}

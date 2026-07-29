import { useCallback, useState } from "react"
import { ConfirmDialog } from "../components/ConfirmDialog"

export interface ConfirmOptions {
  message: string
  confirmLabel?: string
  cancelLabel?: string
  destructive?: boolean
}

interface ConfirmState {
  options: ConfirmOptions
  resolve: (value: boolean) => void
}

export function useConfirm() {
  const [state, setState] = useState<ConfirmState | null>(null)

  const confirm = useCallback((options: ConfirmOptions): Promise<boolean> => {
    return new Promise((resolve) => {
      setState({ options, resolve })
    })
  }, [])

  function onConfirm() {
    if (!state) return
    const { resolve } = state
    setState(null)
    resolve(true)
  }

  function onCancel() {
    if (!state) return
    const { resolve } = state
    setState(null)
    resolve(false)
  }

  const dialog = (
    <ConfirmDialog
      open={state !== null}
      message={state?.options.message ?? ""}
      confirmLabel={state?.options.confirmLabel}
      cancelLabel={state?.options.cancelLabel}
      destructive={state?.options.destructive}
      onConfirm={onConfirm}
      onCancel={onCancel}
    />
  )

  return { confirm, dialog }
}

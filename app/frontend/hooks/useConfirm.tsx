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

  // A second confirm while one is already open used to replace the stored
  // resolver outright, so the first promise could never settle. Whatever
  // awaited it hung forever -- and an awaited confirm sits inside a mutation,
  // so the mutation stayed pending and its button stayed disabled for the life
  // of the page. Settle the outgoing prompt as declined before replacing it:
  // the operator never answered it, which is a decline, and a decline is the
  // safe reading for a destructive command.
  const confirm = useCallback((options: ConfirmOptions): Promise<boolean> => {
    return new Promise((resolve) => {
      setState((previous) => {
        previous?.resolve(false)
        return { options, resolve }
      })
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

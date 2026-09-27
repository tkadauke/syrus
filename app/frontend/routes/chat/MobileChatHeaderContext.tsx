import { createContext, useContext } from "react"

export type MobileChatHeaderControls = {
  autoHideEnabled: boolean
  reportScrollDelta: (delta: number) => void
  revealHeader: () => void
}

const noop = () => {}

export const MobileChatHeaderContext = createContext<MobileChatHeaderControls>({
  autoHideEnabled: false,
  reportScrollDelta: noop,
  revealHeader: noop
})

export function useMobileChatHeaderControls() {
  return useContext(MobileChatHeaderContext)
}

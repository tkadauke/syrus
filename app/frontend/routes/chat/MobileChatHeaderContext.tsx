import { createContext, useContext } from "react"

export type MobileChatHeaderControls = {
  autoHideEnabled: boolean
  hidden: boolean
  hiddenHeight: number
  hideHeader: () => void
  offset: number
  reportScrollDelta: (delta: number) => void
  revealHeader: () => void
  setContentHeight: (height: number) => void
}

const noop = () => {}

export const MobileChatHeaderContext = createContext<MobileChatHeaderControls>({
  autoHideEnabled: false,
  hidden: false,
  hiddenHeight: 0,
  hideHeader: noop,
  offset: 0,
  reportScrollDelta: noop,
  revealHeader: noop,
  setContentHeight: noop
})

export function useMobileChatHeaderControls() {
  return useContext(MobileChatHeaderContext)
}

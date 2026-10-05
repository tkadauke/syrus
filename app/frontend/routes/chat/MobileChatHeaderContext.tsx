import { createContext, useContext } from "react"

export type MobileChatHeaderControls = {
  appHeaderHeight: number
  autoHideEnabled: boolean
  hidden: boolean
  topInset: number
  hideHeader: () => void
  offset: number
  reportScrollDelta: (delta: number) => void
  revealHeader: () => void
  setContentHeight: (height: number) => void
}

const noop = () => {}

export const MobileChatHeaderContext = createContext<MobileChatHeaderControls>({
  appHeaderHeight: 0,
  autoHideEnabled: false,
  hidden: false,
  topInset: 0,
  hideHeader: noop,
  offset: 0,
  reportScrollDelta: noop,
  revealHeader: noop,
  setContentHeight: noop
})

export function useMobileChatHeaderControls() {
  return useContext(MobileChatHeaderContext)
}

import { createContext, useContext } from "react"

export type MobileChromeControls = {
  autoHideEnabled: boolean
  hidden: boolean
  topInset: number
  visibleTopInset: number
  hideHeader: () => void
  offset: number
  reportScrollDelta: (delta: number) => void
  revealHeader: () => void
  setContentHeight: (height: number) => void
}

const noop = () => {}

export const MobileChromeContext = createContext<MobileChromeControls>({
  autoHideEnabled: false,
  hidden: false,
  topInset: 0,
  visibleTopInset: 0,
  hideHeader: noop,
  offset: 0,
  reportScrollDelta: noop,
  revealHeader: noop,
  setContentHeight: noop
})

export function useMobileChromeControls() {
  return useContext(MobileChromeContext)
}

import { createContext, useContext } from "react"

export const MOBILE_CHROME_SURFACE_CLASS = "bg-white dark:bg-gray-950"
export const MOBILE_CHROME_BOTTOM_OVERLAP_CLASS = "shadow-[0_1px_0_0_#fff] dark:shadow-[0_1px_0_0_#030712]"
export const MOBILE_CHROME_TOP_OVERLAP_CLASS = "before:pointer-events-none before:absolute before:inset-x-0 before:-top-[var(--mobile-chrome-top-overlap-height,0px)] before:h-[var(--mobile-chrome-top-overlap-height,0px)] before:bg-white before:content-[''] dark:before:bg-gray-950"

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

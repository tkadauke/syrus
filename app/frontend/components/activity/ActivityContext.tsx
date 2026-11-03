import { createContext, useContext } from "react"

export type ActivityTab = "notifications" | "approvals"

export type ActivityOpenOptions = {
  /** Control that opened Activity; focus returns to it when Activity closes. */
  invoker?: HTMLElement | null
  /** Called after the user navigates away from inside Activity (e.g. to close a sidebar drawer). */
  onNavigate?: () => void
}

export type ActivityControls = {
  /** True when the viewport uses the shared full-screen mobile shell. */
  isMobile: boolean
  open: boolean
  tab: ActivityTab
  openActivity: (tab: ActivityTab, options?: ActivityOpenOptions) => void
  closeActivity: () => void
  selectTab: (tab: ActivityTab) => void
}

export const ActivityContext = createContext<ActivityControls | null>(null)

/** Returns null outside an ActivityProvider so triggers can fall back to their standalone behaviour. */
export function useActivity() {
  return useContext(ActivityContext)
}

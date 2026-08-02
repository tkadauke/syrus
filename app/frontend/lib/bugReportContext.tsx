import { createContext, useContext } from "react"
import type { BugReportOpenOptions, BugReportOptionalAttachment } from "./bugReportOptionalAttachments"

interface BugReportContextValue {
  openBugReport: (options?: BugReportOpenOptions) => void
  registerBugReportAttachments: (attachments: BugReportOptionalAttachment[]) => () => void
}

export const BugReportContext = createContext<BugReportContextValue>({
  openBugReport: () => {},
  registerBugReportAttachments: () => () => {}
})

export function useBugReportTrigger() {
  return useContext(BugReportContext)
}

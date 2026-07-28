import { createContext, useContext } from "react"
import type { ChatMessageItem } from "../api/chats"

interface BugReportContextValue {
  openBugReport: (messages?: ChatMessageItem[]) => void
}

export const BugReportContext = createContext<BugReportContextValue>({
  openBugReport: () => {}
})

export function useBugReportTrigger() {
  return useContext(BugReportContext)
}

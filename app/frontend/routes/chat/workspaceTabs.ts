// Chat workspace tab types + preference helpers extracted from Chat.tsx.
//
// The workspace panel's tab identifiers and the localStorage-backed
// preferences (which tab, collapsed, width) plus the tab label/class helpers.
// Reads the shared workspace constants and the whiteboard element helper;
// lifting the WorkspaceTab/MobileChatTab types here lets the workspace panel
// components move out of the 6k-line Chat.tsx next.
import type { ChatPayload } from "../../api/chats"
import {
  CHAT_WORKSPACE_COLLAPSED_KEY,
  CHAT_WORKSPACE_DEFAULT_WIDTH,
  CHAT_WORKSPACE_MAX_WIDTH,
  CHAT_WORKSPACE_MIN_WIDTH,
  CHAT_WORKSPACE_TAB_KEY,
  CHAT_WORKSPACE_WIDTH_KEY
} from "./constants"
import { codingFilesTabVisible, jobsTabVisible } from "./utils"
import { whiteboardElements } from "./whiteboardScene"

export type WorkspaceTab = "whiteboard" | "context" | "media" | "files" | "diff" | "jobs"
export type MobileChatTab = "chat" | WorkspaceTab

export function workspaceTabClass(active: boolean) {
  return `border-b-2 px-3 py-2 ${active ? "border-blue-600 text-blue-700 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900 dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-100"}`
}

export function workspaceTabLabel(tab: WorkspaceTab, t: (key: string) => string) {
  if (tab === "whiteboard") return t("tab_whiteboard")
  if (tab === "context") return t("tab_context")
  if (tab === "media") return t("tab_media")
  if (tab === "files") return t("tab_files")
  if (tab === "diff") return t("tab_diff")
  if (tab === "jobs") return t("tab_jobs")

  return t("tab_chat")
}

export function mobileChatTabLabel(tab: MobileChatTab, t: (key: string) => string) {
  return tab === "chat" ? t("tab_chat") : workspaceTabLabel(tab, t)
}

export function availableWorkspaceTabs(payload: ChatPayload, simpleMode = false): WorkspaceTab[] {
  return [
    "whiteboard",
    ...(simpleMode ? [] : (["context"] as WorkspaceTab[])),
    "media",
    ...(codingFilesTabVisible(payload) ? (["files"] as WorkspaceTab[]) : []),
    ...(payload.local_tunnel_connected ? (["diff"] as WorkspaceTab[]) : []),
    ...(jobsTabVisible(payload) ? (["jobs"] as WorkspaceTab[]) : [])
  ] as WorkspaceTab[]
}

export function defaultWorkspaceTab(payload: ChatPayload, simpleMode = false): WorkspaceTab {
  const tabs = availableWorkspaceTabs(payload, simpleMode)
  const preferred = whiteboardElements(payload).length > 0 ? "whiteboard" : "context"
  return tabs.includes(preferred) ? preferred : tabs[0]
}

export function storedWorkspaceTab(): WorkspaceTab | null {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_TAB_KEY)
    return value === "whiteboard" || value === "context" || value === "media" || value === "files" || value === "diff" || value === "jobs" ? value : null
  } catch (_error) {
    return null
  }
}

export function storedWorkspaceCollapsed(): boolean {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_COLLAPSED_KEY)
    return value === null ? true : value === "true"
  } catch (_error) {
    return true
  }
}

export function storedWorkspaceWidth() {
  try {
    return clampWorkspaceWidth(Number.parseInt(window.localStorage.getItem(CHAT_WORKSPACE_WIDTH_KEY) || "", 10) || CHAT_WORKSPACE_DEFAULT_WIDTH)
  } catch (_error) {
    return CHAT_WORKSPACE_DEFAULT_WIDTH
  }
}

export function storeWorkspacePreference(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value)
  } catch (_error) {
    // Local storage can be unavailable in hardened browser modes; the
    // workspace still works with in-memory state.
  }
}

export function clampWorkspaceWidth(width: number) {
  return Math.min(Math.max(width, CHAT_WORKSPACE_MIN_WIDTH), CHAT_WORKSPACE_MAX_WIDTH)
}

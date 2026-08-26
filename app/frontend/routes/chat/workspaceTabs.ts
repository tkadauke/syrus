// Chat workspace tab types + preference helpers extracted from Chat.tsx.
//
// The workspace panel's tab identifiers and the localStorage-backed
// preferences (which tab, collapsed, width) plus the tab label/class helpers.
// Reads the shared workspace constants and the whiteboard element helper;
// lifting the WorkspaceTab/MobileChatTab types here lets the workspace panel
// components move out of the 6k-line Chat.tsx next.
import type { ChatPayload, ChatPreviewPanel, ChatWorkspaceTab } from "../../api/chats"
import {
  CHAT_WORKSPACE_COLLAPSED_KEY,
  CHAT_WORKSPACE_DEFAULT_WIDTH,
  CHAT_WORKSPACE_MAX_WIDTH,
  CHAT_WORKSPACE_MIN_WIDTH,
  CHAT_WORKSPACE_TAB_KEY,
  CHAT_WORKSPACE_WIDTH_KEY
} from "./constants"
import { imageAttachments } from "./messageDisplay"
import { codingFilesTabVisible, jobsTabVisible } from "./utils"

// Unlike every other workspace tab kind (a hardcoded singleton), preview
// panels are multi-instance: one tab per open PreviewPanel, keyed by id
// rather than a fixed name.
export type PreviewTab = `preview:${number}`

export function mediaTabVisible(payload: ChatPayload): boolean {
  return imageAttachments(payload.messages).length > 0 ||
    (payload.video_walkthroughs?.length ?? 0) > 0 ||
    (payload.chat.whiteboard_snapshot_count ?? 0) > 0 ||
    (payload.chat.typed_artifact_count ?? 0) > 0
}

// Plugin-provided tabs (see Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md)
// are namespaced under "plugin:" so a plugin's own tab id can never collide
// with one of the fixed core tab names below.
export type PluginTab = `plugin:${string}`
export type WorkspaceTab = "context" | "media" | "pinned" | "files" | "diff" | "jobs" | PreviewTab | PluginTab
export type MobileChatTab = "chat" | WorkspaceTab

export function previewTabId(panelId: number): PreviewTab {
  return `preview:${panelId}`
}

export function isPreviewTab(tab: WorkspaceTab): tab is PreviewTab {
  return tab.startsWith("preview:")
}

export function previewPanelIdFromTab(tab: WorkspaceTab): number | null {
  if (!isPreviewTab(tab)) return null

  const id = Number(tab.slice("preview:".length))
  return Number.isFinite(id) ? id : null
}

export function pluginTabId(tabId: string): PluginTab {
  return `plugin:${tabId}`
}

export function isPluginTab(tab: WorkspaceTab): tab is PluginTab {
  return tab.startsWith("plugin:")
}

export function pluginTabIdFromTab(tab: WorkspaceTab): string | null {
  return isPluginTab(tab) ? tab.slice("plugin:".length) : null
}

export function workspaceTabClass(active: boolean) {
  return `max-w-[33vw] shrink-0 truncate border-b-2 px-3 py-2 ${active ? "border-blue-600 text-blue-700 dark:border-blue-400 dark:text-blue-300" : "border-transparent text-gray-600 hover:border-gray-300 hover:text-gray-900 dark:text-gray-400 dark:hover:border-gray-600 dark:hover:text-gray-100"}`
}

export function workspaceTabLabel(tab: WorkspaceTab, t: (key: string) => string, previewPanels: ChatPreviewPanel[] = [], pluginTabs: ChatWorkspaceTab[] = []) {
  if (tab === "context") return t("tab_context")
  if (tab === "media") return t("tab_media")
  if (tab === "pinned") return t("tab_pinned")
  if (tab === "files") return t("tab_files")
  if (tab === "diff") return t("tab_diff")
  if (tab === "jobs") return t("tab_jobs")
  if (isPreviewTab(tab)) {
    const panelId = previewPanelIdFromTab(tab)
    const panel = previewPanels.find((candidate) => candidate.id === panelId)
    return panel?.title || t("tab_preview")
  }
  if (isPluginTab(tab)) {
    const tabId = pluginTabIdFromTab(tab)
    const pluginTab = pluginTabs.find((candidate) => candidate.id === tabId)
    if (pluginTab?.label_key) return t(pluginTab.label_key)
    return pluginTab?.label || t("tab_plugin")
  }

  return t("tab_chat")
}

export function mobileChatTabLabel(tab: MobileChatTab, t: (key: string) => string, previewPanels: ChatPreviewPanel[] = [], pluginTabs: ChatWorkspaceTab[] = []) {
  return tab === "chat" ? t("tab_chat") : workspaceTabLabel(tab, t, previewPanels, pluginTabs)
}

export function availableWorkspaceTabs(payload: ChatPayload, simpleMode = false, hasPins = false): WorkspaceTab[] {
  return [
    ...(simpleMode ? [] : (["context"] as WorkspaceTab[])),
    ...(mediaTabVisible(payload) ? (["media"] as WorkspaceTab[]) : []),
    ...(hasPins ? (["pinned"] as WorkspaceTab[]) : []),
    ...(codingFilesTabVisible(payload) ? (["files"] as WorkspaceTab[]) : []),
    ...(payload.local_tunnel_connected ? (["diff"] as WorkspaceTab[]) : []),
    ...(jobsTabVisible(payload) ? (["jobs"] as WorkspaceTab[]) : []),
    ...payload.preview_panels.map((panel) => previewTabId(panel.id)),
    ...payload.workspace_tabs.map((tab) => pluginTabId(tab.id))
  ] as WorkspaceTab[]
}

// The whiteboard used to be a hardcoded core tab, and this heuristic
// preferred it as the initial active tab whenever the chat already had
// drawn content (so returning to a chat with a sketch on it opens straight
// to the canvas). Preserving that now that it's a plugin-registered tab
// means reaching for its component key specifically -- an explicit,
// intentional seam rather than the extension point routing "preferred
// default tab" generically. No plugin-declared tab (or a chat with no
// whiteboard content yet) falls back to "context" as before.
const WHITEBOARD_TAB_COMPONENT = "whiteboard_tools/WhiteboardTab"

export function defaultWorkspaceTab(payload: ChatPayload, simpleMode = false): WorkspaceTab {
  const tabs = availableWorkspaceTabs(payload, simpleMode)
  const whiteboardLoaded = payload.whiteboard.loaded ?? payload.whiteboard.elements.length > 0
  const whiteboardTab = payload.workspace_tabs.find((tab) => tab.component === WHITEBOARD_TAB_COMPONENT)
  const preferred = whiteboardLoaded && payload.whiteboard.elements.length > 0 && whiteboardTab
    ? pluginTabId(whiteboardTab.id)
    : "context"
  return tabs.includes(preferred) ? preferred : tabs[0]
}

export function storedWorkspaceTab(): WorkspaceTab | null {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_TAB_KEY)
    if (value === "context" || value === "media" || value === "pinned" || value === "files" || value === "diff" || value === "jobs") return value
    // Plugin tabs (e.g. the whiteboard's "plugin:whiteboard_tools.canvas")
    // are dynamic, so they can't be listed above -- match the "plugin:"
    // namespace instead. Preserves the pre-migration behavior where the
    // (then-core) "whiteboard" tab survived a reload.
    if (value && isPluginTab(value as WorkspaceTab)) return value as PluginTab
    return null
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

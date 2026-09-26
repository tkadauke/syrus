// Chat workspace tab types + preference helpers extracted from Chat.tsx.
//
// The workspace panel's tab identifiers and the localStorage-backed
// preferences (which tab, collapsed, width) plus the tab label/class helpers.
// Reads the shared workspace constants and the whiteboard element helper;
// lifting the WorkspaceTab/MobileChatTab types here lets the workspace panel
// components move out of the 6k-line Chat.tsx next.
import type { ChatPayload, ChatPreviewPanel, ChatWorkspaceTab } from "../../api/chats"
import { underlineTabClass } from "../../components/Tabs"
import {
  CHAT_WORKSPACE_COLLAPSED_KEY,
  CHAT_WORKSPACE_DEFAULT_WIDTH,
  CHAT_WORKSPACE_MAX_WIDTH,
  CHAT_WORKSPACE_MIN_WIDTH,
  CHAT_WORKSPACE_TAB_KEY,
  CHAT_WORKSPACE_WIDTH_KEY,
  CHAT_FILES_TREE_COLLAPSED_KEY,
  CHAT_FILES_TREE_DEFAULT_WIDTH,
  CHAT_FILES_TREE_MAX_WIDTH,
  CHAT_FILES_TREE_MIN_WIDTH,
  CHAT_FILES_TREE_WIDTH_KEY,
  CHAT_DIFF_FILES_COLLAPSED_KEY,
  CHAT_DIFF_FILES_WIDTH_KEY
} from "./constants"
import { codingFilesTabVisible, jobsTabVisible, localDiffTabVisible, readOnlyFilesTabVisible, runtimeTabVisible } from "./utils"

// Unlike every other workspace tab kind (a hardcoded singleton), preview
// panels are multi-instance: one tab per open PreviewPanel, keyed by id
// rather than a fixed name.
export type PreviewTab = `preview:${number}`

// Sourced from payload.chat.has_chat_images (the chat's full message
// history) rather than scanning payload.messages -- the currently loaded
// message window is paginated, so an older image that scrolled out of the
// loaded tail would otherwise hide the tab even though the chat has media.
export function mediaTabVisible(payload: ChatPayload): boolean {
  return (payload.chat.chat_image_count ?? 0) > 0 ||
    (payload.chat.has_chat_images ?? false) ||
    (payload.video_walkthroughs?.length ?? 0) > 0 ||
    (payload.chat.whiteboard_snapshot_count ?? 0) > 0 ||
    (payload.chat.typed_artifact_count ?? 0) > 0
}

// Plugin-provided tabs (see Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md)
// are namespaced under "plugin:" so a plugin's own tab id can never collide
// with one of the fixed core tab names below.
export type PluginTab = `plugin:${string}`
export type WorkspaceTab = "media" | "pinned" | "files" | "diff" | "jobs" | "runtime" | PreviewTab | PluginTab
export type MobileChatTab = "chat" | WorkspaceTab

export function previewTabId(panelId: number): PreviewTab {
  return `preview:${panelId}`
}

export function isPreviewTab(tab: WorkspaceTab | null): tab is PreviewTab {
  return tab != null && tab.startsWith("preview:")
}

export function previewPanelIdFromTab(tab: WorkspaceTab): number | null {
  if (!isPreviewTab(tab)) return null

  const id = Number(tab.slice("preview:".length))
  return Number.isFinite(id) ? id : null
}

export function pluginTabId(tabId: string): PluginTab {
  return `plugin:${tabId}`
}

export function isPluginTab(tab: WorkspaceTab | null): tab is PluginTab {
  return tab != null && tab.startsWith("plugin:")
}

export function pluginTabIdFromTab(tab: WorkspaceTab): string | null {
  return isPluginTab(tab) ? tab.slice("plugin:".length) : null
}

export function workspaceTabClass(active: boolean) {
  return underlineTabClass(active, "max-w-[33vw] truncate px-3 py-2")
}

export function workspaceTabLabel(tab: WorkspaceTab, t: (key: string) => string, previewPanels: ChatPreviewPanel[] = [], pluginTabs: ChatWorkspaceTab[] = []) {
  if (tab === "media") return t("tab_media")
  if (tab === "pinned") return t("tab_pinned")
  if (tab === "files") return t("tab_files")
  if (tab === "diff") return t("tab_diff")
  if (tab === "jobs") return t("tab_jobs")
  if (tab === "runtime") return t("tab_runtime")
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

export function availableWorkspaceTabs(payload: ChatPayload, hasPins = false): WorkspaceTab[] {
  return [
    ...(mediaTabVisible(payload) ? (["media"] as WorkspaceTab[]) : []),
    ...(hasPins ? (["pinned"] as WorkspaceTab[]) : []),
    ...(codingFilesTabVisible(payload) || readOnlyFilesTabVisible(payload) ? (["files"] as WorkspaceTab[]) : []),
    ...(localDiffTabVisible(payload) ? (["diff"] as WorkspaceTab[]) : []),
    ...(jobsTabVisible(payload) ? (["jobs"] as WorkspaceTab[]) : []),
    ...(runtimeTabVisible(payload) ? (["runtime"] as WorkspaceTab[]) : []),
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
// whiteboard content yet) falls back to the first available tab.
const WHITEBOARD_TAB_COMPONENT = "whiteboard/WhiteboardTab"

// Returns null when the chat currently has no workspace tabs to show at all
// (e.g. a repository-less chat with no media/pins/jobs and no plugin tabs
// registered) -- unlike the old hardcoded "context" tab, nothing here is
// guaranteed to always be present, so callers must treat "no tab selected"
// as a valid state rather than assuming a WorkspaceTab always exists.
export function defaultWorkspaceTab(payload: ChatPayload): WorkspaceTab | null {
  const tabs = availableWorkspaceTabs(payload)
  const whiteboardLoaded = payload.whiteboard.loaded ?? payload.whiteboard.elements.length > 0
  const whiteboardTab = payload.workspace_tabs.find((tab) => tab.component === WHITEBOARD_TAB_COMPONENT)
  if (whiteboardLoaded && payload.whiteboard.elements.length > 0 && whiteboardTab) {
    const preferred = pluginTabId(whiteboardTab.id)
    if (tabs.includes(preferred)) return preferred
  }
  return tabs[0] ?? null
}

export function storedWorkspaceTab(): WorkspaceTab | null {
  try {
    const value = window.localStorage.getItem(CHAT_WORKSPACE_TAB_KEY)
    if (value === "media" || value === "pinned" || value === "files" || value === "diff" || value === "jobs" || value === "runtime") return value
    // Plugin tabs (e.g. the whiteboard's "plugin:whiteboard.canvas")
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

export function storedFilesTreeCollapsed(): boolean {
  try {
    return window.localStorage.getItem(CHAT_FILES_TREE_COLLAPSED_KEY) === "true"
  } catch (_error) {
    return false
  }
}

export function storedFilesTreeWidth() {
  try {
    return clampFilesTreeWidth(Number.parseInt(window.localStorage.getItem(CHAT_FILES_TREE_WIDTH_KEY) || "", 10) || CHAT_FILES_TREE_DEFAULT_WIDTH)
  } catch (_error) {
    return CHAT_FILES_TREE_DEFAULT_WIDTH
  }
}

// Diff tab file list uses its own persisted preference keys (separate from
// the Files tree above) so resizing/collapsing one pane doesn't affect the
// other, while sharing the same width bounds and default for a consistent
// affordance.
export function storedDiffFilesCollapsed(): boolean {
  try {
    return window.localStorage.getItem(CHAT_DIFF_FILES_COLLAPSED_KEY) === "true"
  } catch (_error) {
    return false
  }
}

export function storedDiffFilesWidth() {
  try {
    return clampFilesTreeWidth(Number.parseInt(window.localStorage.getItem(CHAT_DIFF_FILES_WIDTH_KEY) || "", 10) || CHAT_FILES_TREE_DEFAULT_WIDTH)
  } catch (_error) {
    return CHAT_FILES_TREE_DEFAULT_WIDTH
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

export function clampFilesTreeWidth(width: number) {
  return Math.min(Math.max(width, CHAT_FILES_TREE_MIN_WIDTH), CHAT_FILES_TREE_MAX_WIDTH)
}

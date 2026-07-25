import { type BootstrapPayload } from "../../api/bootstrap"
import { type ChatGroupRecord, type ChatNavRecord } from "../../api/chats"


// Pure app-chrome helpers extracted from AppChromeV2.tsx: path/route classifiers,
// link/query builders, chat sort/title helpers, sidebar-width persistence, and
// nav/popup class helpers, plus the sidebar-width constants. No JSX or hooks.

export const SIDEBAR_WIDTH_KEY = "syrus.sidebar.width"
export const SIDEBAR_DEFAULT_WIDTH = 240
export const SIDEBAR_MIN_WIDTH = 208
export const SIDEBAR_MAX_WIDTH = 420

export function updateBootstrapTheme(payload: BootstrapPayload | undefined, theme: "light" | "dark") {
  if (!payload?.current_user) return payload

  return {
    ...payload,
    current_user: {
      ...payload.current_user,
      theme
    }
  }
}

export function normalizedAppPath(pathname: string) {
  return pathname.replace(/^\/app-shell/, "") || "/"
}

export function redirectsToSetup(data: BootstrapPayload | null | undefined, normalizedPath: string) {
  if (!data?.setup || data.setup.complete) return false
  if (data.setup.chat_started) return false
  return normalizedPath === "/" || normalizedPath.startsWith("/dashboard")
}

export function isAdminPath(pathname: string) {
  return pathname === "/admin" ||
    pathname.startsWith("/admin/") ||
    pathname === "/invitations" ||
    pathname === "/settings/edit"
}

export function isAuthPath(pathname: string) {
  return pathname === "/session/new" ||
    pathname === "/users/new" ||
    pathname === "/passwords/new" ||
    pathname.startsWith("/passwords/")
}

export function adminNavItemActive(pathname: string, navPath: string) {
  if (navPath === "/admin") return pathname === navPath

  return pathname === navPath || pathname.startsWith(`${navPath}/`)
}

export { withRoutePrefix } from "../../lib/routing"

export function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

export function activeChatIdFromPath(pathname: string) {
  const match = normalizedAppPath(pathname).match(/^\/chats\/(\d+)(?:\/|$)/)
  return match ? Number(match[1]) : null
}

export function bugReportContext(pathname: string) {
  const normalized = normalizedAppPath(pathname)
  if (normalized === "/" || normalized === "/dashboard") return "Dashboard"

  const label = normalized
    .split("/")
    .filter(Boolean)
    .filter((segment) => !/^\d+$/.test(segment))
    .map((segment) => segment.replace(/_/g, " "))
    .join(" ")

  return label ? titleize(label) : "Syrus"
}

export function titleize(value: string) {
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase())
}

export type ChatSection = {
  key: string
  label: string
  repository_id: number | null
  chats: ChatNavRecord[]
  has_more: boolean
}

export function chatSectionsFromPayload(groups: ChatGroupRecord[], loadedSections: Record<string, { chats: ChatNavRecord[]; has_more: boolean }>) {
  return groups.map((group) => {
    const loaded = loadedSections[group.key]
    const seen = new Set<number>()
    const chats = [...group.chats, ...(loaded?.chats || [])]
      .filter((chat) => {
        if (seen.has(chat.id)) return false

        seen.add(chat.id)
        return true
      })
      .sort(compareChatsByLastMessage)
    return {
      key: group.key,
      label: group.label,
      repository_id: group.repository_id,
      chats,
      has_more: loaded?.has_more ?? group.has_more,
      activeAt: Math.max(...chats.map(chatActivityTime))
    }
  })
    .sort((left, right) => right.activeAt - left.activeAt)
    .map(({ activeAt: _activeAt, ...group }) => group)
}

export function compareChatsByLastMessage(left: ChatNavRecord, right: ChatNavRecord) {
  if (left.pinned !== right.pinned) return left.pinned ? -1 : 1

  return chatActivityTime(right) - chatActivityTime(left) || right.id - left.id
}

export function chatLastMessageTime(chat: ChatNavRecord) {
  return timestampValue(chat.last_message_at)
}

export function chatActivityTime(chat: ChatNavRecord) {
  return chatLastMessageTime(chat) || timestampValue(chat.created_at)
}

export function timestampValue(value?: string | null) {
  if (!value) return 0

  const timestamp = Date.parse(value)
  return Number.isNaN(timestamp) ? 0 : timestamp
}

export function sidebarChatTitle(chat: Pick<ChatNavRecord, "title" | "title_pending">, newChatTitle: string) {
  if (chat.title_pending) return newChatTitle
  return chat.title?.trim() || newChatTitle
}

export function storedSidebarWidth() {
  try {
    return clampSidebarWidth(Number.parseInt(window.localStorage.getItem(SIDEBAR_WIDTH_KEY) || "", 10) || SIDEBAR_DEFAULT_WIDTH)
  } catch (_error) {
    return SIDEBAR_DEFAULT_WIDTH
  }
}

export function storeSidebarWidth(width: number) {
  try {
    window.localStorage.setItem(SIDEBAR_WIDTH_KEY, String(width))
  } catch (_error) {
    // Local storage can be unavailable in hardened browser modes; the
    // sidebar still resizes for the current session.
  }
}

export function clampSidebarWidth(width: number) {
  return Math.min(Math.max(width, SIDEBAR_MIN_WIDTH), SIDEBAR_MAX_WIDTH)
}

export function sidebarLinkClass(active: boolean) {
  return `inline-flex min-h-[44px] w-full items-center gap-2 rounded px-2.5 py-2 font-medium ${active ? "text-blue-700 dark:text-blue-300 sm:bg-blue-50 dark:sm:bg-blue-900/30" : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"}`
}

export function recentChatLinkClass(active: boolean) {
  return `flex min-w-0 w-full items-start gap-2 rounded px-2 py-1.5 text-xs ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

export function adminSubnavLinkClass(active: boolean) {
  return `block whitespace-nowrap rounded px-3 py-3 font-medium ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

export function popupLinkClass() {
  return "block px-4 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
}

export function popupButtonClass() {
  return "block w-full px-4 py-2 text-left text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-60 dark:text-gray-200 dark:hover:bg-gray-800"
}

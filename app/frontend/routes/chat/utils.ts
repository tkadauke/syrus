// Pure value/string/display utilities extracted from Chat.tsx.
//
// Mostly generic coercion/normalization helpers (no chat types) plus a few
// small chat-payload display predicates/formatters. Lifting them into a leaf
// module lets the rendering helpers and components move out of the 6k-line
// Chat.tsx without importing back from it.
import type { ChatNavRecord, ChatPayload, WhiteboardSnapshot } from "../../api/chats"
import { CHAT_ENTER_SUBMIT_MIN_WIDTH } from "./constants"

export function stringValue(value: unknown) {
  return typeof value === "string" ? value : value == null ? "" : String(value)
}

export function stringArray(value: unknown) {
  return Array.isArray(value) ? value.map(stringValue).filter(Boolean) : []
}

export function contentRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
}

export function contentInput(content: unknown) {
  return contentRecord(contentRecord(content)?.input) || {}
}

export function firstLine(value: string) {
  return value.split(/\r?\n/, 1)[0].trim()
}

export function humanize(value: string) {
  const normalized = value.replace(/_id$/, "").replace(/_/g, " ").toLowerCase()
  return normalized ? normalized[0].toUpperCase() + normalized.slice(1) : ""
}

export function numericArg(value: string) {
  const match = value.trim().match(/^\d+$/)
  return match ? match[0] : null
}

export function errorAsError(error: unknown) {
  return error instanceof Error ? error : new Error(String(error))
}

export { formatCurrency } from "../../lib/format"

export function formatTokenCount(value: number) {
  if (value < 1000) return new Intl.NumberFormat("en-US").format(value)

  const thousands = value / 1000
  const compact = Number.isInteger(thousands) ? String(thousands) : thousands.toFixed(1).replace(/\.0$/, "")
  return `${compact}k`
}

export function parsePixelValue(value: string) {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function truncateSnapshotName(name: string) {
  return name.length > 40 ? `${name.slice(0, 39)}...` : name
}

export function providerLabel(provider: string) {
  if (provider === "claude") return "Claude"
  if (provider === "codex") return "Codex"
  return provider
}

export function startOfLocalDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate())
}

export function sameLocalDay(left: Date, right: Date) {
  return left.getFullYear() === right.getFullYear() && left.getMonth() === right.getMonth() && left.getDate() === right.getDate()
}

export function appendSearch(path: string, search: string) {
  return search ? `${path}${search}` : path
}

export function primaryButton() {
  return "flex h-11 items-center justify-center rounded bg-blue-600 px-3 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-60 dark:bg-blue-500 dark:hover:bg-blue-400"
}

export function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
}

export function diffLineClass(line: string): string {
  if (line.startsWith("+++") || line.startsWith("---")) {
    return "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
  }
  if (line.startsWith("@@")) {
    return "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300"
  }
  if (line.startsWith("+")) {
    return "bg-green-50 text-green-800 dark:bg-green-950 dark:text-green-200"
  }
  if (line.startsWith("-")) {
    return "bg-red-50 text-red-800 dark:bg-red-950 dark:text-red-200"
  }
  return "text-gray-800 dark:text-gray-200"
}

export function dayDividerLabel(date: Date) {
  const today = startOfLocalDay(new Date())
  const candidate = startOfLocalDay(date)
  const dayDelta = Math.round((today.getTime() - candidate.getTime()) / (24 * 60 * 60 * 1000))

  if (dayDelta === 0) return "Today"
  if (dayDelta === 1) return "Yesterday"

  return date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" })
}

export function codingFilesTabVisible(payload: ChatPayload): boolean {
  return Boolean(
    payload.coding_mode_enabled &&
    payload.chat.mode === "coding" &&
    payload.chat.coding_checkout_branch
  )
}

export function jobsTabVisible(payload: ChatPayload): boolean {
  return (payload.chat.confirmed_proposal_count ?? 0) > 0 ||
    (payload.chat.linked_direct_job_count ?? 0) > 0
}

export function currentRecentChat(payload: ChatPayload) {
  return payload.recent_chats.find((chat) => chat.id === payload.chat.id)
}

export function chatDisplayTitle(chat: Pick<ChatNavRecord, "id" | "title" | "title_pending" | "repository">) {
  if (chat.title_pending) return "Naming chat..."

  return chat.title || chat.repository?.slug || `Chat #${chat.id}`
}

export function snapshotKindLabel(kind: WhiteboardSnapshot["snapshot_kind"]) {
  if (kind === "auto_clear") return "Before clear"
  if (kind === "auto_before_load") return "Before load"
  return "Saved"
}
export function isDesktopChatViewport() {
  return typeof window !== "undefined" && window.innerWidth >= CHAT_ENTER_SUBMIT_MIN_WIDTH
}

export function visualViewportHeight() {
  if (typeof window === "undefined" || !window.visualViewport) return null

  return Math.round(window.visualViewport.height)
}

export { withRoutePrefix } from "../../lib/routing"

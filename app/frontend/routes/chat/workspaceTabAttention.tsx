// Unread-attention model for the chat workspace tabs.
//
// Chat activity never moves the operator's selected tab. Instead, content that
// lands in a tab the operator is not looking at raises a red badge on that tab:
// a number for countable additions (confirmed Jobs, media, screenshots) and an
// unnumbered dot for changes that cannot be counted (a whiteboard mutation, a
// preview update, a generic plugin-tab update). Selecting/viewing the tab clears it.
import { useCallback, useEffect, useRef, useState, type ReactNode } from "react"
import type { ChatPayload } from "../../api/chats"
import { previewTabId, pluginTabId, type WorkspaceTab } from "./workspaceTabs"
import { AttentionBadge } from "../../components/AttentionBadge"

export type TabAttention = { count: number; dot: boolean }
export type TabAttentionMap = Partial<Record<WorkspaceTab, TabAttention>>
export type TabAttentionEvent = { tab: WorkspaceTab; count?: number }

const MAX_BADGE_COUNT = 9
const COUNT_BADGE_CLASS = "ml-1.5 inline-flex min-w-4 shrink-0 items-center justify-center rounded-full px-1"
const COUNT_TEXT_CLASS = "text-2xs font-semibold leading-4"

// Plugin tabs signal change through their own `data`; the whiteboard's scene
// lives outside tab data (payload.whiteboard), so a component may register an
// extra signature here. Tabs without an entry still badge via `data` changes.
const PLUGIN_COMPONENT_SIGNALS: Record<string, (payload: ChatPayload) => string | null> = {
  "whiteboard/WhiteboardTab": (payload) => (payload.whiteboard?.loaded ? String(payload.whiteboard.version) : null)
}

export function mediaItemCount(payload: ChatPayload) {
  return (
    (payload.chat.chat_image_count ?? (payload.chat.has_chat_images ? 1 : 0)) +
    (payload.video_walkthroughs?.length ?? 0) +
    (payload.chat.whiteboard_snapshot_count ?? 0) +
    (payload.chat.typed_artifact_count ?? 0)
  )
}

export type AttentionSnapshot = {
  chatId: ChatPayload["chat"]["id"]
  mediaCount: number
  // null signature = "not known yet" (e.g. the whiteboard has not loaded), which never counts as a change.
  signatures: Partial<Record<WorkspaceTab, string | null>>
}

export function attentionSnapshot(payload: ChatPayload): AttentionSnapshot {
  const signatures: AttentionSnapshot["signatures"] = {}
  for (const panel of payload.preview_panels) {
    signatures[previewTabId(panel.id)] = `${panel.current_version_id ?? ""}:${panel.file_count}:${panel.title}`
  }
  for (const tab of payload.workspace_tabs) {
    const signal = PLUGIN_COMPONENT_SIGNALS[tab.component]?.(payload) ?? null
    signatures[pluginTabId(tab.id)] = JSON.stringify([tab.data ?? null, signal])
    if (signal === null && PLUGIN_COMPONENT_SIGNALS[tab.component]) signatures[pluginTabId(tab.id)] = null
  }
  return { chatId: payload.chat.id, mediaCount: mediaItemCount(payload), signatures }
}

// Events between two snapshots of the same chat. A tab that first appears
// counts as activity (dot); a media increase is a countable delta.
export function attentionEvents(previous: AttentionSnapshot, next: AttentionSnapshot): TabAttentionEvent[] {
  if (previous.chatId !== next.chatId) return []

  const events: TabAttentionEvent[] = []
  if (next.mediaCount > previous.mediaCount) events.push({ tab: "media", count: next.mediaCount - previous.mediaCount })
  for (const [tab, signature] of Object.entries(next.signatures) as [WorkspaceTab, string | null][]) {
    const before = previous.signatures[tab]
    if (before === undefined) events.push({ tab })
    else if (before !== null && signature !== null && before !== signature) events.push({ tab })
  }
  return events
}

export function applyAttention(map: TabAttentionMap, event: TabAttentionEvent): TabAttentionMap {
  const current = map[event.tab] ?? { count: 0, dot: false }
  const count = event.count && event.count > 0 ? event.count : 0
  return { ...map, [event.tab]: { count: current.count + count, dot: current.dot || count === 0 } }
}

// `visibleTab` is the tab the operator can currently see (null when the
// workspace is collapsed or, on mobile, the chat surface is showing).
export function useWorkspaceTabAttention(payload: ChatPayload, visibleTab: WorkspaceTab | null) {
  const [attention, setAttention] = useState<TabAttentionMap>({})
  const snapshotRef = useRef<AttentionSnapshot>(attentionSnapshot(payload))
  const visibleTabRef = useRef(visibleTab)
  visibleTabRef.current = visibleTab

  const notify = useCallback((event: TabAttentionEvent) => {
    if (event.tab === visibleTabRef.current) return
    setAttention((current) => applyAttention(current, event))
  }, [])

  useEffect(() => {
    const next = attentionSnapshot(payload)
    const events = attentionEvents(snapshotRef.current, next)
    if (snapshotRef.current.chatId !== next.chatId) setAttention({})
    snapshotRef.current = next
    events.forEach(notify)
  }, [payload, notify])

  useEffect(() => {
    if (visibleTab === null) return
    setAttention((current) => {
      if (!current[visibleTab]) return current
      const { [visibleTab]: _cleared, ...rest } = current
      return rest
    })
  }, [visibleTab, attention])

  return { attention, notify }
}

export function hasTabAttention(attention: TabAttentionMap) {
  return Object.values(attention).some((entry) => entry && (entry.count > 0 || entry.dot))
}

type Translate = (key: string, options?: Record<string, unknown>) => string

export function workspaceTabBadge(entry: TabAttention | undefined, t: Translate): ReactNode {
  if (!entry || (entry.count <= 0 && !entry.dot)) return undefined

  if (entry.count > 0) {
    const text = entry.count > MAX_BADGE_COUNT ? `${MAX_BADGE_COUNT}+` : String(entry.count)
    return (
      <AttentionBadge className={COUNT_BADGE_CLASS} data-testid="workspace-tab-badge">
        <span aria-hidden="true" className={COUNT_TEXT_CLASS}>
          {text}
        </span>
        <span className="sr-only">{t("tab_attention_new_items", { count: entry.count })}</span>
      </AttentionBadge>
    )
  }

  return (
    <span className="ml-1.5 inline-flex shrink-0 items-center" data-testid="workspace-tab-badge">
      <span aria-hidden="true" className="h-2 w-2 rounded-full bg-danger" />
      <span className="sr-only">{t("tab_attention_new_activity")}</span>
    </span>
  )
}

import { ChevronDownIcon, HideIcon, PlusIcon, TargetIcon, TeamIcon } from "./icons"
import { type ChatSection, activeChatIdFromPath, chatSectionsFromPayload, recentChatLinkClass, sidebarChatTitle, withRoutePrefix } from "./helpers"
import { FloatingPortal, flip, offset, shift, useFloating, useMergeRefs } from "@floating-ui/react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type FormEvent, useEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { useTranslation } from "react-i18next"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { DEFAULT_CHAT_SIDEBAR_SETTINGS, cancelCodingCheckout, deleteChat, fetchChat, fetchChats, fetchMoreChatsForGroup, hideChat, markChatRead, markChatUnread, renameChat, updateChatPinned, type ChatMode, type ChatNavRecord, type ChatPayload, type ChatSidebarGroupBy, type ChatSidebarPerGroup, type ChatSidebarSettings, type ChatSidebarSortBy, type ChatSidebarStatus, type ChatsIndexPayload } from "../../api/chats"
import { ApiError } from "../../api/client"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { CopyableSlug } from "../../components/CopyableSlug"
import { Input } from "../../components/Input"
import { PinIcon } from "../../components/PinIcon"
import { ProviderAvailabilityWarning } from "../../components/ProviderAvailabilityWarning"
import { Surface, surfaceClasses } from "../../components/ui"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { recentChatsQueryKey, updateChatUnread, updateRecentChatCache } from "../../lib/chatCache"
import { chatQueryKey } from "../Chat"

const SIDEBAR_SETTINGS_KEY = "syrus.recent_chats_sidebar.settings"
const DEFAULT_SIDEBAR_SETTINGS = DEFAULT_CHAT_SIDEBAR_SETTINGS
const STATUS_OPTIONS: Array<{ value: ChatSidebarStatus; label: string }> = [
  { value: "active", label: "Active" },
  { value: "hidden", label: "Hidden" },
  { value: "all", label: "All" }
]
const GROUP_BY_OPTIONS: Array<{ value: ChatSidebarGroupBy; label: string }> = [
  { value: "date", label: "Date" },
  { value: "repository", label: "Repository" },
  { value: "status", label: "Status" },
  { value: "mode", label: "Mode" }
]
const SORT_BY_OPTIONS: Array<{ value: ChatSidebarSortBy; label: string }> = [
  { value: "name", label: "Name" },
  { value: "date_created", label: "Date created" },
  { value: "last_activity", label: "Last activity" }
]
const PER_GROUP_OPTIONS: ChatSidebarPerGroup[] = [5, 10, 15, 20]
const SIDEBAR_MENU_ROW_CLASS = "flex w-full items-center gap-3 px-3 py-2 text-left text-text-primary hover:bg-surface-subtle"
const SIDEBAR_ACTION_BUTTON_CLASS = "flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-text-primary hover:bg-surface-subtle"
const SIDEBAR_DANGER_BUTTON_CLASS = "flex w-full items-center gap-2 px-3 py-2 text-left text-danger-text hover:bg-danger-surface disabled:cursor-not-allowed disabled:opacity-60"
const SIDEBAR_DIVIDER_CLASS = "my-1 border-t border-border"
const SIDEBAR_DIALOG_CLOSE_CLASS = "rounded p-1 text-text-secondary hover:bg-surface-subtle hover:text-text-primary"

// Recent-chats sidebar extracted from AppChromeV2.tsx: the recent-chats list
// (RecentChatsSidebar) with its activity marker and per-chat actions menu.
// Entry point rendered by the sidebar. Depends only on leaf modules.

function findScrollParent(el: HTMLElement): HTMLElement | null {
  let parent = el.parentElement
  while (parent) {
    const overflow = getComputedStyle(parent).overflowY
    if (overflow === "auto" || overflow === "scroll") return parent
    parent = parent.parentElement
  }
  return null
}

function readSidebarSettings(): ChatSidebarSettings {
  try {
    const raw = window.localStorage.getItem(SIDEBAR_SETTINGS_KEY)
    if (!raw) return DEFAULT_SIDEBAR_SETTINGS

    const parsed = JSON.parse(raw) as Partial<ChatSidebarSettings> | null
    if (!parsed || typeof parsed !== "object") return DEFAULT_SIDEBAR_SETTINGS

    return normalizeSidebarSettings(parsed)
  } catch {
    return DEFAULT_SIDEBAR_SETTINGS
  }
}

function writeSidebarSettings(settings: ChatSidebarSettings) {
  try {
    window.localStorage.setItem(SIDEBAR_SETTINGS_KEY, JSON.stringify(settings))
  } catch {
    // Sidebar settings are a convenience preference; the default view still works.
  }
}

function normalizeSidebarSettings(settings: Partial<ChatSidebarSettings>): ChatSidebarSettings {
  const status = STATUS_OPTIONS.some((option) => option.value === settings.status) ? settings.status as ChatSidebarStatus : DEFAULT_SIDEBAR_SETTINGS.status
  const groupBy = GROUP_BY_OPTIONS.some((option) => option.value === settings.group_by) ? settings.group_by as ChatSidebarGroupBy : DEFAULT_SIDEBAR_SETTINGS.group_by
  const sortBy = SORT_BY_OPTIONS.some((option) => option.value === settings.sort_by) ? settings.sort_by as ChatSidebarSortBy : DEFAULT_SIDEBAR_SETTINGS.sort_by
  const perGroup = PER_GROUP_OPTIONS.includes(settings.per_group as ChatSidebarPerGroup) ? settings.per_group as ChatSidebarPerGroup : DEFAULT_SIDEBAR_SETTINGS.per_group

  return {
    status,
    group_by: groupBy,
    sort_by: sortBy,
    show_empty_groups: groupBy === "date" ? false : settings.show_empty_groups === true,
    per_group: perGroup
  }
}

function updateSidebarSettings(current: ChatSidebarSettings, patch: Partial<ChatSidebarSettings>) {
  return normalizeSidebarSettings({ ...current, ...patch })
}

export function RecentChatsSidebar({ featureFlags, onCloseDrawer, onNotice, onStartChat, prefix, startingChat = false, userPresent }: {
  featureFlags: Record<string, boolean>
  onCloseDrawer: () => void
  onNotice: (message: string | null) => void
  onStartChat?: (repositoryId?: number | null) => void
  prefix: string
  startingChat?: boolean
  userPresent: boolean
}) {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { t } = useTranslation(["common", "chat"])
  const codingModeEnabled = featureFlags.coding_mode === true
  const localModeEnabled = featureFlags.local_mode === true
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(() => new Set())
  const [loadedSections, setLoadedSections] = useState<Record<string, { chats: ChatNavRecord[]; has_more: boolean }>>({})
  const [loadingSections, setLoadingSections] = useState<Set<string>>(() => new Set())
  const [hidingChatIds, setHidingChatIds] = useState<Set<number>>(() => new Set())
  const [deletingChatIds, setDeletingChatIds] = useState<Set<number>>(() => new Set())
  const [sidebarSettings, setSidebarSettings] = useState<ChatSidebarSettings>(readSidebarSettings)
  const [draggingOverChatId, setDraggingOverChatId] = useState<number | null>(null)
  const navigateTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const sidebarRootRef = useRef<HTMLDivElement>(null)
  const scrollRafRef = useRef<number | null>(null)
  const activeChatId = activeChatIdFromPath(location.pathname)
  const sidebarQueryKey = useMemo(() => recentChatsQueryKey(sidebarSettings), [sidebarSettings])
  const chats = useQuery({
    queryKey: sidebarQueryKey,
    queryFn: () => fetchChats(sidebarSettings),
    enabled: userPresent,
    staleTime: 30_000
  })
  const settingsKey = useMemo(() => JSON.stringify(sidebarSettings), [sidebarSettings])
  const sections = useMemo(() => chatSectionsFromPayload(chats.data?.groups || [], loadedSections), [chats.data?.groups, loadedSections])

  useEffect(() => {
    writeSidebarSettings(sidebarSettings)
    setLoadedSections({})
    setLoadingSections(new Set())
  }, [settingsKey])

  function showLess(key: string) {
    setLoadedSections((current) => {
      const next = { ...current }
      delete next[key]
      return next
    })
  }

  function toggleCollapsedSection(key: string) {
    setCollapsedSections((current) => {
      const next = new Set(current)
      if (next.has(key)) {
        next.delete(key)
      } else {
        next.add(key)
      }
      return next
    })
  }

  function showMore(section: ChatSection) {
    const beforeChat = section.chats[section.chats.length - 1]
    if (!beforeChat || loadingSections.has(section.key)) return

    setLoadingSections((current) => new Set(current).add(section.key))
    void fetchMoreChatsForGroup(section, beforeChat.id, sidebarSettings).then((payload) => {
      setLoadedSections((current) => {
        const existing = current[section.key]
        const existingIds = new Set([
          ...section.chats.map((chat) => chat.id),
          ...(existing?.chats.map((chat) => chat.id) || [])
        ])
        const nextChats = payload.chats.filter((chat) => !existingIds.has(chat.id))

        return {
          ...current,
          [section.key]: {
            chats: [...(existing?.chats || []), ...nextChats],
            has_more: payload.has_more
          }
        }
      })
    }).finally(() => {
      setLoadingSections((current) => {
        const next = new Set(current)
        next.delete(section.key)
        return next
      })
    })
  }

  function hideRecentChat(chat: ChatNavRecord) {
    if (hidingChatIds.has(chat.id)) return

    setHidingChatIds((current) => new Set(current).add(chat.id))
    removeChatFromRecentLists(chat.id)
    void hideChat(chat.id).then(() => {
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      void queryClient.invalidateQueries({ queryKey: ["hidden-chats"] })
      if (chat.id === activeChatId) navigate(`${prefix}/dashboard/jobs`)
    }).catch(() => {
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }).finally(() => {
      setHidingChatIds((current) => {
        const next = new Set(current)
        next.delete(chat.id)
        return next
      })
    })
  }

  function deleteRecentChat(chat: ChatNavRecord) {
    if (deletingChatIds.has(chat.id)) return

    setDeletingChatIds((current) => new Set(current).add(chat.id))
    void deleteChat(chat.id).then(() => {
      removeChatFromRecentLists(chat.id)
      queryClient.removeQueries({ queryKey: ["chats", String(chat.id)] })
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      void queryClient.invalidateQueries({ queryKey: ["hidden-chats"] })
      onNotice(t("chat:chat_deleted"))
      if (chat.id === activeChatId) navigate(`${prefix}/dashboard/jobs`)
    }).catch((error) => {
      onNotice(error instanceof ApiError && error.message ? error.message : t("chat:unable_to_delete"))
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }).finally(() => {
      setDeletingChatIds((current) => {
        const next = new Set(current)
        next.delete(chat.id)
        return next
      })
    })
  }

  function togglePin(chat: ChatNavRecord) {
    void updateChatPinned(chat.id, !chat.pinned).then(() => {
      onNotice(null)
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }).catch(() => {
      onNotice(t("chat:unable_to_update_pin"))
    })
  }

  function removeChatFromRecentLists(chatId: number) {
    queryClient.setQueryData<ChatsIndexPayload>(sidebarQueryKey, (current) => {
      if (!current) return current

      return {
        ...current,
        groups: current.groups
          .map((group) => ({ ...group, chats: group.chats.filter((chat) => chat.id !== chatId) }))
          .filter((group) => group.chats.length > 0)
      }
    })
    setLoadedSections((current) => {
      const next: Record<string, { chats: ChatNavRecord[]; has_more: boolean }> = {}
      Object.entries(current).forEach(([key, value]) => {
        next[key] = { ...value, chats: value.chats.filter((chat) => chat.id !== chatId) }
      })
      return next
    })
  }

  useEffect(() => {
    return () => {
      if (navigateTimerRef.current !== null) clearTimeout(navigateTimerRef.current)
      if (scrollRafRef.current !== null) cancelAnimationFrame(scrollRafRef.current)
    }
  }, [])

  if (!userPresent) return null

  return (
    <div
      className="px-3 pb-4"
      onDragEnd={() => {
        if (scrollRafRef.current !== null) cancelAnimationFrame(scrollRafRef.current)
        scrollRafRef.current = null
      }}
      onDragLeave={(e) => {
        if (e.currentTarget.contains(e.relatedTarget as Node | null)) return
        if (scrollRafRef.current !== null) cancelAnimationFrame(scrollRafRef.current)
        scrollRafRef.current = null
      }}
      onDragOver={(e) => {
        e.preventDefault()
        const container = findScrollParent(e.currentTarget)
        if (!container) return
        const rect = container.getBoundingClientRect()
        const relY = e.clientY - rect.top
        if (scrollRafRef.current !== null) {
          cancelAnimationFrame(scrollRafRef.current)
          scrollRafRef.current = null
        }
        if (relY < 60) {
          const scrollUp = () => {
            container.scrollBy(0, -8)
            scrollRafRef.current = requestAnimationFrame(scrollUp)
          }
          scrollRafRef.current = requestAnimationFrame(scrollUp)
        } else if (relY > rect.height - 60) {
          const scrollDown = () => {
            container.scrollBy(0, 8)
            scrollRafRef.current = requestAnimationFrame(scrollDown)
          }
          scrollRafRef.current = requestAnimationFrame(scrollDown)
        }
      }}
      ref={sidebarRootRef}
    >
      <div className="mb-2 flex items-center justify-between gap-2 px-2">
        <div className="min-w-0 text-2xs font-semibold uppercase tracking-normal text-gray-500 dark:text-gray-400">{t("nav:recent_chats_aria")}</div>
        <RecentChatsSettingsMenu settings={sidebarSettings} setSettings={setSidebarSettings} />
      </div>
      <nav aria-label={t("nav:recent_chats_aria")} className="space-y-4">
        {sections.map((section) => {
          const collapsed = collapsedSections.has(section.key)
          const loaded = loadedSections[section.key]
          const loading = loadingSections.has(section.key)
          const visibleChats = collapsed ? [] : section.chats
          const canShowMore = !collapsed && section.has_more
          const canShowLess = !collapsed && Boolean(loaded)

          return (
            <section className="space-y-1" key={section.key}>
              <h2 className="flex min-w-0 items-center gap-1">
                <button
                  aria-expanded={!collapsed}
                  className="flex min-w-0 flex-1 items-center gap-1 rounded px-2 py-1 text-left text-2xs font-semibold uppercase tracking-normal text-gray-500 hover:bg-gray-100 hover:text-brand dark:text-gray-400 dark:hover:bg-gray-800"
                  onClick={() => toggleCollapsedSection(section.key)}
                  type="button"
                >
                  <ChevronDownIcon className={collapsed ? "-rotate-90" : ""} />
                  <span className="min-w-0 flex-1 truncate">{section.label}</span>
                </button>
                {section.group_by === "repository" && section.repository_id != null && onStartChat ? (
                  <button
                    aria-label={`New chat in ${section.label}`}
                    className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-400 dark:hover:bg-gray-800"
                    disabled={startingChat}
                    onClick={() => onStartChat(section.repository_id)}
                    title={`New chat in ${section.label}`}
                    type="button"
                  >
                    <PlusIcon />
                  </button>
                ) : null}
              </h2>
              <div className="space-y-0.5">
                {visibleChats.map((chat) => {
                  const active = chat.id === activeChatId
                  const unread = chat.unread && !active
                  return (
                    <div
                      className={`group relative flex min-w-0 items-center rounded${draggingOverChatId === chat.id ? " animate-drag-blink dark:animate-drag-blink-dark" : ""}`}
                      key={chat.id}
                      onDragEnter={(e) => {
                        e.preventDefault()
                        if (draggingOverChatId === chat.id) return
                        if (navigateTimerRef.current !== null) clearTimeout(navigateTimerRef.current)
                        setDraggingOverChatId(chat.id)
                        navigateTimerRef.current = setTimeout(() => {
                          navigate(withRoutePrefix(chat.chat_path, prefix))
                          onCloseDrawer()
                          setDraggingOverChatId(null)
                        }, 1000)
                      }}
                      onDragLeave={(e) => {
                        if (e.currentTarget.contains(e.relatedTarget as Node | null)) return
                        if (navigateTimerRef.current !== null) clearTimeout(navigateTimerRef.current)
                        setDraggingOverChatId(null)
                      }}
                      onDragOver={(e) => e.preventDefault()}
                    >
                      <Link
                        className={`${recentChatLinkClass(active)} pr-9`}
                        onClick={onCloseDrawer}
                        to={withRoutePrefix(chat.chat_path, prefix)}
                      >
                        <ChatModeIcon codingModeEnabled={codingModeEnabled} localModeEnabled={localModeEnabled} mode={chat.mode} />
                        {chat.conversation_kind === "group" ? (
                          <span className="contents" data-testid="group-chat-icon">
                            <TeamIcon className="mt-0.5 h-3.5 w-3.5 shrink-0 text-purple-500 dark:text-purple-400" />
                          </span>
                        ) : null}
                        {chat.pinned ? (
                          <PinIcon className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand" />
                        ) : null}
                        <ProviderAvailabilityWarning availability={chat.provider_availability} className="mt-0.5" />
                        <span className={`min-w-0 flex-1 truncate ${unread ? "font-semibold" : "font-medium"}`}>{sidebarChatTitle(chat, t("chat:new_title"))}</span>
                        <span className="flex shrink-0 items-start gap-1 group-hover:hidden">
                          <RecentChatActivityMarker active={Boolean(chat.turn_in_flight || chat.agent_busy)} unread={unread} />
                          {chat.active_goal && (chat.active_goal.status === "active" || chat.active_goal.status === "paused") ? (
                            <span
                              className={`mt-0.5 shrink-0 ${chat.active_goal.status === "paused" ? "text-amber-500 opacity-60 dark:text-amber-400" : "text-emerald-600 dark:text-emerald-400"}`}
                              data-testid="chat-goal-marker"
                              title={chat.active_goal.status === "paused" ? t("nav:title_goal_paused") : t("nav:title_goal_active")}
                            >
                              <TargetIcon className="h-3.5 w-3.5" />
                            </span>
                          ) : null}
                          {chat.pending_proposal_count > 0 && (
                            <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-amber-400 dark:bg-amber-500" />
                          )}
                          {chat.coding_checkout_uncommitted && (
                            <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-amber-500 dark:bg-amber-400" title={t("nav:title_uncommitted")} />
                          )}
                          {chat.scratchpad_items_count > 0 && (
                            <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-teal-500 dark:bg-teal-400" title={t("nav:title_scratchpad")} />
                          )}
                        </span>
                      </Link>
                      <RecentChatActionsMenu
                        chat={chat}
                        deleteDisabled={deletingChatIds.has(chat.id)}
                        disabled={hidingChatIds.has(chat.id)}
                        onDelete={() => deleteRecentChat(chat)}
                        onHide={() => hideRecentChat(chat)}
                        onNotice={onNotice}
                        onTogglePin={() => togglePin(chat)}
                        search={location.search}
                      />
                    </div>
                  )
                })}
              </div>
              {canShowMore || canShowLess ? (
                <div className="ml-6 flex flex-wrap gap-1">
                  {canShowMore ? (
                    <button
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-brand disabled:cursor-not-allowed disabled:text-gray-300 dark:text-gray-400 dark:hover:bg-gray-800"
                      disabled={loading}
                      onClick={() => showMore(section)}
                      type="button"
                    >
                      {loading ? t("common:loading") : t("common:show_more")}
                    </button>
                  ) : null}
                  {canShowLess ? (
                    <button
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-brand dark:text-gray-400 dark:hover:bg-gray-800"
                      onClick={() => showLess(section.key)}
                      type="button"
                    >
                      {t("common:show_less")}
                    </button>
                  ) : null}
                </div>
              ) : null}
            </section>
          )
        })}
      </nav>
    </div>
  )
}

function RecentChatsSettingsMenu({ settings, setSettings }: {
  settings: ChatSidebarSettings
  setSettings: (updater: (current: ChatSidebarSettings) => ChatSidebarSettings) => void
}) {
  const [open, setOpen] = useState(false)
  const [submenu, setSubmenu] = useState<"root" | "status" | "group_by" | "sort_by" | "per_group">("root")
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => {
    setOpen(false)
    setSubmenu("root")
  })
  const statusLabel = optionLabel(STATUS_OPTIONS, settings.status)
  const groupByLabel = optionLabel(GROUP_BY_OPTIONS, settings.group_by)
  const sortByLabel = optionLabel(SORT_BY_OPTIONS, settings.sort_by)

  function apply(patch: Partial<ChatSidebarSettings>) {
    setSettings((current) => updateSidebarSettings(current, patch))
  }

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-label="Recent chats settings"
        className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand dark:text-gray-400 dark:hover:bg-gray-800"
        onClick={() => setOpen((value) => !value)}
        title="Recent chats settings"
        type="button"
      >
        <SettingsSlidersIcon />
      </button>
      {open ? (
        <Surface className="absolute right-0 z-40 mt-1 w-64 py-1 text-sm shadow-lg" padding="none" variant="raised">
          {submenu === "root" ? (
            <>
              <SettingsParentRow current={statusLabel} label="Status" onClick={() => setSubmenu("status")} />
              <SettingsParentRow current={groupByLabel} label="Group by" onClick={() => setSubmenu("group_by")} />
              <SettingsParentRow current={sortByLabel} label="Sort by" onClick={() => setSubmenu("sort_by")} />
              {settings.group_by !== "date" ? (
                <button
                  className={`${SIDEBAR_MENU_ROW_CLASS} justify-between`}
                  onClick={() => apply({ show_empty_groups: !settings.show_empty_groups })}
                  role="switch"
                  aria-checked={settings.show_empty_groups}
                  type="button"
                >
                  <span>Show empty groups</span>
                  <span className={`h-5 w-9 rounded-full p-0.5 ${settings.show_empty_groups ? "bg-brand" : "bg-border"}`}>
                    <span className={`block h-4 w-4 rounded-full bg-white transition-transform ${settings.show_empty_groups ? "translate-x-4" : ""}`} />
                  </span>
                </button>
              ) : null}
              <SettingsParentRow current={String(settings.per_group)} label="Chats per group" onClick={() => setSubmenu("per_group")} />
            </>
          ) : null}
          {submenu === "status" ? (
            <SettingsOptionList
              label="Status"
              onBack={() => setSubmenu("root")}
              onSelect={(value) => apply({ status: value as ChatSidebarStatus })}
              options={STATUS_OPTIONS}
              value={settings.status}
            />
          ) : null}
          {submenu === "group_by" ? (
            <SettingsOptionList
              label="Group by"
              onBack={() => setSubmenu("root")}
              onSelect={(value) => apply({ group_by: value as ChatSidebarGroupBy })}
              options={GROUP_BY_OPTIONS}
              value={settings.group_by}
            />
          ) : null}
          {submenu === "sort_by" ? (
            <SettingsOptionList
              label="Sort by"
              onBack={() => setSubmenu("root")}
              onSelect={(value) => apply({ sort_by: value as ChatSidebarSortBy })}
              options={SORT_BY_OPTIONS}
              value={settings.sort_by}
            />
          ) : null}
          {submenu === "per_group" ? (
            <SettingsOptionList
              label="Chats per group"
              onBack={() => setSubmenu("root")}
              onSelect={(value) => apply({ per_group: Number(value) as ChatSidebarPerGroup })}
              options={PER_GROUP_OPTIONS.map((value) => ({ value: String(value), label: String(value) }))}
              value={String(settings.per_group)}
            />
          ) : null}
        </Surface>
      ) : null}
    </div>
  )
}

function SettingsParentRow({ current, label, onClick }: { current: string; label: string; onClick: () => void }) {
  return (
    <button className={SIDEBAR_MENU_ROW_CLASS} onClick={onClick} type="button">
      <span className="min-w-0 flex-1">{label}</span>
      <span className="truncate text-xs text-text-secondary">{current}</span>
      <ChevronRightIcon />
    </button>
  )
}

function SettingsOptionList<T extends string>({ label, onBack, onSelect, options, value }: { label: string; onBack: () => void; onSelect: (value: T) => void; options: Array<{ value: T; label: string }>; value: T }) {
  return (
    <>
      <button className={`${SIDEBAR_MENU_ROW_CLASS} font-semibold`} onClick={onBack} type="button">
        <ChevronRightIcon className="rotate-180" />
        {label}
      </button>
      <div className={SIDEBAR_DIVIDER_CLASS} />
      {options.map((option) => (
        <button
          className={SIDEBAR_MENU_ROW_CLASS}
          key={option.value}
          onClick={() => onSelect(option.value)}
          type="button"
        >
          <CheckIcon visible={option.value === value} />
          <span>{option.label}</span>
        </button>
      ))}
    </>
  )
}

function optionLabel<T extends string>(options: Array<{ value: T; label: string }>, value: T) {
  return options.find((option) => option.value === value)?.label || value
}

function SettingsSlidersIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M5 7h9m3 0h2M5 12h2m3 0h9M5 17h7m3 0h4" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
      <circle cx="16" cy="7" r="1.75" stroke="currentColor" strokeWidth="1.6" />
      <circle cx="9" cy="12" r="1.75" stroke="currentColor" strokeWidth="1.6" />
      <circle cx="14" cy="17" r="1.75" stroke="currentColor" strokeWidth="1.6" />
    </svg>
  )
}

function ChevronRightIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 shrink-0 ${className}`} fill="none" viewBox="0 0 24 24">
      <path d="m9 6 6 6-6 6" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function CheckIcon({ visible }: { visible: boolean }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 shrink-0 ${visible ? "text-brand" : "text-transparent"}`} fill="none" viewBox="0 0 24 24">
      <path d="m5 12 4 4 10-10" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
  )
}

function RecentChatActivityMarker({ active, unread }: { active: boolean; unread: boolean }) {
  const { t } = useTranslation("nav")
  if (active) {
    return (
      <span aria-hidden="true" className="mt-[0.35rem] inline-flex h-2 w-3.5 shrink-0 items-center justify-between" title={t("nav:title_turn_active")}>
        {[0, 1, 2].map((index) => (
          <span
            aria-hidden="true"
            className="h-1 w-1 animate-bounce rounded-full bg-brand"
            key={index}
            style={{ animationDelay: `${index * 140}ms` }}
          />
        ))}
      </span>
    )
  }

  return <span className={`mt-1 h-2 w-2 shrink-0 rounded-full ${unread ? "bg-brand" : "bg-transparent"}`} />
}

function ChatModeIcon({ codingModeEnabled, localModeEnabled, mode }: { codingModeEnabled: boolean; localModeEnabled: boolean; mode?: ChatMode | null }) {
  if (codingModeEnabled && mode === "coding") {
    return (
      <svg aria-hidden="true" className="mt-0.5 h-3.5 w-3.5 shrink-0 text-indigo-400 dark:text-indigo-400" data-testid="mode-icon-coding" fill="none" viewBox="0 0 24 24">
        <polyline points="4 17 10 11 4 5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
        <line stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" x1="12" x2="20" y1="19" y2="19" />
      </svg>
    )
  }
  if (localModeEnabled && mode === "local") {
    return (
      <svg aria-hidden="true" className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-500 dark:text-emerald-400" data-testid="mode-icon-local" fill="none" viewBox="0 0 24 24">
        <path d="M4 17.5V6a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v11.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
        <path d="M2 19h20" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
      </svg>
    )
  }
  return (
    <svg aria-hidden="true" className="mt-0.5 h-3.5 w-3.5 shrink-0 text-gray-300 dark:text-gray-600" data-testid="mode-icon-planning" fill="none" viewBox="0 0 24 24">
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
      <path d="M14 2v6h6M16 13H8M16 17H8" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
    </svg>
  )
}

function RecentChatActionsMenu({ chat, deleteDisabled = false, disabled, onDelete, onHide, onNotice, onTogglePin, search }: {
  chat: ChatNavRecord
  deleteDisabled?: boolean
  disabled: boolean
  onDelete: () => void
  onHide: () => void
  onNotice: (message: string | null) => void
  onTogglePin: () => void
  search: string
}) {
  const location = useLocation()
  const queryClient = useQueryClient()
  const { t } = useTranslation("chat")
  const [open, setOpen] = useState(false)
  const [renameOpen, setRenameOpen] = useState(false)
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false)
  // Dropdown opens upward by default (placement "top-end", matching the old
  // fixed `bottom-full right-0`), but flip/shift reposition it within the
  // viewport when a chat near the top of the sidebar leaves no room above
  // the trigger — otherwise rows at the top of a tall menu render off-screen
  // with no way to scroll back up to them.
  const { floatingStyles, refs: floatingRefs } = useFloating({
    middleware: [offset(4), flip(), shift({ padding: 8 })],
    placement: "top-end"
  })
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false), [floatingRefs.floating])
  const referenceRef = useMergeRefs([menuRef, floatingRefs.setReference])
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const active = chat.id === activeChatIdFromPath(location.pathname)
  const queryKey = chatQueryKey(String(chat.id), search)
  const cachedChatData = queryClient.getQueryData<ChatPayload>(queryKey)
  const chatBookmarks = useQuery({
    queryKey,
    queryFn: () => fetchChat(String(chat.id), search),
    enabled: open && !cachedChatData
  })
  const chatData = open ? cachedChatData ?? chatBookmarks.data : undefined
  const bookmarks = chatData?.bookmarks ?? []
  const loadingBookmarks = open && !chatData && chatBookmarks.isPending

  const markRead = useMutation({
    mutationFn: () => markChatRead(chat.id),
    onSuccess: () => {
      updateChatUnread(queryClient, chat.id, false)
      setOpen(false)
    }
  })

  const markUnread = useMutation({
    mutationFn: () => markChatUnread(chat.id),
    onSuccess: () => {
      updateChatUnread(queryClient, chat.id, true)
      setOpen(false)
    }
  })

  const rename = useMutation({
    mutationFn: (title: string) => renameChat(`/api/v1/app/chats/${chat.id}/rename`, title),
    onSuccess: (payload) => {
      updateRecentChatCache(queryClient, payload.chat)
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      void queryClient.invalidateQueries({ queryKey: ["chats", String(chat.id)] })
      setRenameOpen(false)
      onNotice(null)
    },
    onError: (error) => {
      onNotice(error instanceof ApiError && error.message ? error.message : t("chat:unable_to_rename"))
    }
  })

  const discardCodingChanges = useMutation({
    mutationFn: () => cancelCodingCheckout(`/api/v1/app/chats/${chat.id}/coding_checkout`),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      void queryClient.invalidateQueries({ queryKey: ["chats", String(chat.id)] })
      setOpen(false)
      onNotice(t("chat:coding_checkout_cancelled_notice"))
    },
    onError: (error) => {
      onNotice(error instanceof ApiError && error.message ? error.message : t("chat:coding_checkout_cancel_error"))
    }
  })

  function submitRename(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (rename.isPending) return

    const form = event.currentTarget
    const title = new FormData(form).get("chat_title")?.toString().trim() || ""
    if (title.length === 0) return

    rename.mutate(title)
  }

  return (
    <div className="absolute right-1 top-1/2 z-10 -translate-y-1/2" ref={referenceRef}>
      <button
        aria-expanded={open}
        aria-label={`Chat actions for ${sidebarChatTitle(chat, t("chat:new_title"))}`}
        className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 opacity-0 hover:bg-brand/10 hover:text-brand focus:opacity-100 dark:text-gray-400 group-hover:opacity-100"
        onClick={() => setOpen((value) => !value)}
        type="button"
      >
        ...
      </button>
      {open ? (
        <FloatingPortal>
          <div
            className={surfaceClasses("raised", "none", "z-50 w-48 py-1 text-xs")}
            ref={floatingRefs.setFloating}
            style={floatingStyles}
          >
          {loadingBookmarks ? (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">{t("chat:loading_bookmarks")}</div>
          ) : bookmarks.length > 0 ? (
            <>
              <div className="px-3 py-2 font-semibold text-gray-700 dark:text-gray-200">{t("chat:bookmarks")}</div>
              <div className="max-h-48 overflow-y-auto">
                {bookmarks.map((bookmark) => {
                  const anchorMessageId = bookmark.anchor_message_id ?? bookmark.chat_message_id

                  return (
                    <a
                      className="block truncate px-3 py-2 text-gray-700 hover:bg-brand/10 hover:text-brand dark:text-gray-300"
                      href={active ? `#message-${anchorMessageId}` : withRoutePrefix(`${chat.chat_path}#message-${anchorMessageId}`, prefix)}
                      key={bookmark.id}
                      onClick={() => setOpen(false)}
                    >
                      {bookmark.label}
                    </a>
                  )
                })}
              </div>
            </>
          ) : (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">{t("chat:no_bookmarks")}</div>
          )}
          <div className={SIDEBAR_DIVIDER_CLASS} />
          <button
            className={SIDEBAR_ACTION_BUTTON_CLASS}
            onClick={() => {
              onTogglePin()
              setOpen(false)
            }}
            type="button"
          >
            <PinIcon className="h-4 w-4 shrink-0" />
            {chat.pinned ? t("chat:unpin") : t("chat:pin")}
          </button>
          <button
            className={SIDEBAR_ACTION_BUTTON_CLASS}
            disabled={markRead.isPending || markUnread.isPending}
            onClick={() => chat.unread ? markRead.mutate() : markUnread.mutate()}
            type="button"
          >
            {chat.unread ? t("chat:mark_as_read") : t("chat:mark_as_unread")}
          </button>
          <button
            className={SIDEBAR_ACTION_BUTTON_CLASS}
            onClick={() => {
              setOpen(false)
              setRenameOpen(true)
            }}
            type="button"
          >
            {t("chat:rename")}
          </button>
          {chat.coding_checkout_uncommitted ? (
            <button
              className={`${SIDEBAR_ACTION_BUTTON_CLASS} text-warning-text hover:bg-warning-surface disabled:cursor-not-allowed disabled:opacity-60`}
              disabled={discardCodingChanges.isPending}
              onClick={() => discardCodingChanges.mutate()}
              type="button"
            >
              {t("chat:discard_coding_changes")}
            </button>
          ) : null}
          <div className={SIDEBAR_DIVIDER_CLASS} />
          <div className="px-3 py-1.5">
            <CopyableSlug slug={`CHAT-${chat.id}`} />
          </div>
          <div className={SIDEBAR_DIVIDER_CLASS} />
          <button
            className={SIDEBAR_DANGER_BUTTON_CLASS}
            disabled={disabled}
            onClick={() => {
              setOpen(false)
              onHide()
            }}
            type="button"
          >
            <HideIcon />
            <span>{t("chat:hide")}</span>
          </button>
          <button
            className={SIDEBAR_DANGER_BUTTON_CLASS}
            disabled={deleteDisabled}
            onClick={() => {
              setOpen(false)
              setDeleteConfirmOpen(true)
            }}
            type="button"
          >
            <CloseIcon className="h-4 w-4 shrink-0" />
            <span>{t("chat:delete")}</span>
          </button>
          </div>
        </FloatingPortal>
      ) : null}
      {/* Both confirm dialogs render through a portal: this menu wrapper is
          `absolute … -translate-y-1/2`, and a CSS transform makes an ancestor
          the containing block for fixed-position descendants — an inline
          `fixed inset-0` overlay here would be sized/clipped to the chat row
          instead of the viewport. */}
      {renameOpen ? createPortal(
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
          <form aria-modal="true" className={surfaceClasses("panel", "md", "w-full max-w-sm shadow-xl")} onSubmit={submitRename} role="dialog">
            <div className="flex items-start justify-between gap-3">
              <h2 className="text-base font-semibold text-text-primary">{t("chat:rename_chat_title")}</h2>
              <button aria-label={t("chat:cancel")} className={SIDEBAR_DIALOG_CLOSE_CLASS} disabled={rename.isPending} onClick={() => setRenameOpen(false)} type="button">
                <CloseIcon className="h-4 w-4" />
              </button>
            </div>
            <label className="mt-4 block text-sm font-medium text-text-primary" htmlFor={`rename-chat-${chat.id}`}>{t("chat:rename_chat_label")}</label>
            <Input
              autoFocus
              className="mt-1"
              defaultValue={chat.title || ""}
              disabled={rename.isPending}
              id={`rename-chat-${chat.id}`}
              maxLength={120}
              name="chat_title"
              required
              type="text"
            />
            <div className="mt-4 flex justify-end gap-2">
              <Button disabled={rename.isPending} onClick={() => setRenameOpen(false)} variant="secondary">{t("chat:cancel")}</Button>
              <Button disabled={rename.isPending} type="submit" variant="primary">{t("chat:save")}</Button>
            </div>
          </form>
        </div>,
        document.body
      ) : null}
      {deleteConfirmOpen ? createPortal(
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
          <Surface aria-modal="true" className="w-full max-w-sm shadow-xl" role="dialog">
            <div className="flex items-start justify-between gap-3">
              <h2 className="text-base font-semibold text-text-primary">{t("chat:delete_chat_title")}</h2>
              <button aria-label={t("chat:cancel")} className={SIDEBAR_DIALOG_CLOSE_CLASS} onClick={() => setDeleteConfirmOpen(false)} type="button">
                <CloseIcon className="h-4 w-4" />
              </button>
            </div>
            <p className="mt-3 text-sm text-text-secondary">{t("chat:delete_confirm_body")}</p>
            <div className="mt-4 flex justify-end gap-2">
              <Button onClick={() => setDeleteConfirmOpen(false)} variant="secondary">{t("chat:cancel")}</Button>
              <Button
                disabled={deleteDisabled}
                onClick={() => {
                  setDeleteConfirmOpen(false)
                  onDelete()
                }}
                variant="danger"
              >
                {t("chat:delete_confirm")}
              </Button>
            </div>
          </Surface>
        </div>,
        document.body
      ) : null}
    </div>
  )
}

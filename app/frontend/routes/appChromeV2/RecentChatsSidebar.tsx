import { ChevronDownIcon, HideIcon } from "./icons"
import { type ChatSection, activeChatIdFromPath, chatSectionsFromPayload, recentChatLinkClass, sidebarChatTitle, withRoutePrefix } from "./helpers"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type FormEvent, useMemo, useState } from "react"
import { createPortal } from "react-dom"
import { useTranslation } from "react-i18next"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { cancelCodingCheckout, deleteChat, fetchChat, fetchChats, fetchMoreChatsForGroup, hideChat, markChatRead, markChatUnread, renameChat, updateChatPinned, type ChatMode, type ChatNavRecord, type ChatPayload, type ChatsIndexPayload } from "../../api/chats"
import { ApiError } from "../../api/client"
import { CloseIcon } from "../../components/CloseIcon"
import { PinIcon } from "../../components/PinIcon"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { updateChatUnread } from "../../lib/chatCache"
import { chatQueryKey } from "../Chat"


// Recent-chats sidebar extracted from AppChromeV2.tsx: the recent-chats list
// (RecentChatsSidebar) with its activity marker and per-chat actions menu.
// Entry point rendered by the sidebar. Depends only on leaf modules.

export function RecentChatsSidebar({ featureFlags, onCloseDrawer, onNotice, prefix, userPresent }: { featureFlags: Record<string, boolean>; onCloseDrawer: () => void; onNotice: (message: string | null) => void; prefix: string; userPresent: boolean }) {
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
  const activeChatId = activeChatIdFromPath(location.pathname)
  const chats = useQuery({
    queryKey: ["chats", "recent"],
    queryFn: fetchChats,
    enabled: userPresent,
    staleTime: 30_000
  })
  const sections = useMemo(() => chatSectionsFromPayload(chats.data?.groups || [], loadedSections), [chats.data?.groups, loadedSections])

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
    void fetchMoreChatsForGroup(section.repository_id, beforeChat.id).then((payload) => {
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
    queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
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

  if (!userPresent) return null

  return (
    <div className="px-3 pb-4">
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
              <h2>
                <button
                  aria-expanded={!collapsed}
                  className="flex w-full min-w-0 items-center gap-1 rounded px-2 py-1 text-left text-[0.68rem] font-semibold uppercase tracking-normal text-gray-500 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
                  onClick={() => toggleCollapsedSection(section.key)}
                  type="button"
                >
                  <ChevronDownIcon className={collapsed ? "-rotate-90" : ""} />
                  <span className="min-w-0 flex-1 truncate">{section.label}</span>
                </button>
              </h2>
              <div className="space-y-0.5">
                {visibleChats.map((chat) => {
                  const active = chat.current || chat.id === activeChatId
                  const unread = chat.unread && !active
                  return (
                    <div className="group relative flex min-w-0 items-center" key={chat.id}>
                      <Link
                        className={`${recentChatLinkClass(active)} pr-9`}
                        onClick={onCloseDrawer}
                        to={withRoutePrefix(chat.chat_path, prefix)}
                      >
                        <ChatModeIcon codingModeEnabled={codingModeEnabled} localModeEnabled={localModeEnabled} mode={chat.mode} />
                        {chat.pinned ? (
                          <PinIcon className="mt-0.5 h-3.5 w-3.5 shrink-0 text-blue-600 dark:text-blue-300" />
                        ) : null}
                        <span className={`min-w-0 flex-1 truncate ${unread ? "font-semibold" : "font-medium"}`}>{sidebarChatTitle(chat, t("chat:new_title"))}</span>
                        <span className="flex shrink-0 items-start gap-1 group-hover:hidden">
                          <RecentChatActivityMarker active={Boolean(chat.turn_in_flight || chat.agent_busy)} unread={unread} />
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
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-blue-700 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
                      disabled={loading}
                      onClick={() => showMore(section)}
                      type="button"
                    >
                      {loading ? t("common:loading") : t("common:show_more")}
                    </button>
                  ) : null}
                  {canShowLess ? (
                    <button
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
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

function RecentChatActivityMarker({ active, unread }: { active: boolean; unread: boolean }) {
  const { t } = useTranslation("nav")
  if (active) {
    return (
      <span aria-hidden="true" className="mt-[0.35rem] inline-flex h-2 w-3.5 shrink-0 items-center justify-between" title={t("nav:title_turn_active")}>
        {[0, 1, 2].map((index) => (
          <span
            aria-hidden="true"
            className="h-1 w-1 animate-bounce rounded-full bg-blue-600 dark:bg-blue-300"
            key={index}
            style={{ animationDelay: `${index * 140}ms` }}
          />
        ))}
      </span>
    )
  }

  return <span className={`mt-1 h-2 w-2 shrink-0 rounded-full ${unread ? "bg-blue-600 dark:bg-blue-400" : "bg-transparent"}`} />
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
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const active = chat.current || chat.id === activeChatIdFromPath(location.pathname)
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
    onSuccess: () => {
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
    <div className="absolute right-1 top-1/2 -translate-y-1/2" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-label={`Chat actions for ${sidebarChatTitle(chat, t("chat:new_title"))}`}
        className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 opacity-0 hover:bg-blue-100 hover:text-blue-700 focus:opacity-100 dark:text-gray-400 dark:hover:bg-blue-900 dark:hover:text-blue-200 group-hover:opacity-100"
        onClick={() => setOpen((value) => !value)}
        type="button"
      >
        ...
      </button>
      {open ? (
        <div className="absolute bottom-full right-0 z-20 mb-1 w-48 rounded border border-gray-200 bg-white py-1 text-xs shadow-lg dark:border-gray-700 dark:bg-gray-950">
          {loadingBookmarks ? (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">{t("chat:loading_bookmarks")}</div>
          ) : bookmarks.length > 0 ? (
            <>
              <div className="px-3 py-2 font-semibold text-gray-700 dark:text-gray-200">{t("chat:bookmarks")}</div>
              {bookmarks.map((bookmark) => {
                const anchorMessageId = bookmark.anchor_message_id ?? bookmark.chat_message_id

                return (
                  <a
                    className="block truncate px-3 py-2 text-gray-700 hover:bg-blue-50 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-blue-950 dark:hover:text-blue-200"
                    href={active ? `#message-${anchorMessageId}` : withRoutePrefix(`${chat.chat_path}#message-${anchorMessageId}`, prefix)}
                    key={bookmark.id}
                    onClick={() => setOpen(false)}
                  >
                    {bookmark.label}
                  </a>
                )
              })}
            </>
          ) : (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">{t("chat:no_bookmarks")}</div>
          )}
          <button
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
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
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
            disabled={markRead.isPending || markUnread.isPending}
            onClick={() => chat.unread ? markRead.mutate() : markUnread.mutate()}
            type="button"
          >
            {chat.unread ? "Mark as read" : "Mark as unread"}
          </button>
          <button
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
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
              className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-amber-700 hover:bg-amber-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-amber-300 dark:hover:bg-amber-950/40"
              disabled={discardCodingChanges.isPending}
              onClick={() => discardCodingChanges.mutate()}
              type="button"
            >
              {t("chat:discard_coding_changes")}
            </button>
          ) : null}
          <div className="my-1 border-t border-gray-200 dark:border-gray-700" />
          <button
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-red-300 dark:hover:bg-red-950/40"
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
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-red-300 dark:hover:bg-red-950/40"
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
      ) : null}
      {/* Both confirm dialogs render through a portal: this menu wrapper is
          `absolute … -translate-y-1/2`, and a CSS transform makes an ancestor
          the containing block for fixed-position descendants — an inline
          `fixed inset-0` overlay here would be sized/clipped to the chat row
          instead of the viewport. */}
      {renameOpen ? createPortal(
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
          <form aria-modal="true" className="w-full max-w-sm rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-950" onSubmit={submitRename} role="dialog">
            <div className="flex items-start justify-between gap-3">
              <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("chat:rename_chat_title")}</h2>
              <button aria-label={t("chat:cancel")} className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" disabled={rename.isPending} onClick={() => setRenameOpen(false)} type="button">
                <CloseIcon className="h-4 w-4" />
              </button>
            </div>
            <label className="mt-4 block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor={`rename-chat-${chat.id}`}>{t("chat:rename_chat_label")}</label>
            <input
              autoFocus
              className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
              defaultValue={chat.title || ""}
              disabled={rename.isPending}
              id={`rename-chat-${chat.id}`}
              maxLength={120}
              name="chat_title"
              required
              type="text"
            />
            <div className="mt-4 flex justify-end gap-2">
              <button className="rounded border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" disabled={rename.isPending} onClick={() => setRenameOpen(false)} type="button">{t("chat:cancel")}</button>
              <button className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:bg-blue-300" disabled={rename.isPending} type="submit">{t("chat:save")}</button>
            </div>
          </form>
        </div>,
        document.body
      ) : null}
      {deleteConfirmOpen ? createPortal(
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/30 p-4" role="presentation">
          <div aria-modal="true" className="w-full max-w-sm rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-950" role="dialog">
            <div className="flex items-start justify-between gap-3">
              <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("chat:delete_chat_title")}</h2>
              <button aria-label={t("chat:cancel")} className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" onClick={() => setDeleteConfirmOpen(false)} type="button">
                <CloseIcon className="h-4 w-4" />
              </button>
            </div>
            <p className="mt-3 text-sm text-gray-700 dark:text-gray-300">{t("chat:delete_confirm_body")}</p>
            <div className="mt-4 flex justify-end gap-2">
              <button className="rounded border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={() => setDeleteConfirmOpen(false)} type="button">{t("chat:cancel")}</button>
              <button
                className="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:bg-red-300"
                disabled={deleteDisabled}
                onClick={() => {
                  setDeleteConfirmOpen(false)
                  onDelete()
                }}
                type="button"
              >
                {t("chat:delete_confirm")}
              </button>
            </div>
          </div>
        </div>,
        document.body
      ) : null}
    </div>
  )
}

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useState } from "react"
import { ApiError } from "../api/client"
import { fetchHiddenChats, unhideChat, type HiddenChatRecord } from "../api/chats"
import { NoticeToast } from "../components/NoticeToast"
import { useT } from "../hooks/useT"

export function HiddenChatsRoute() {
  const [notice, setNotice] = useState<string | null>(null)
  const { t } = useT("chat")

  return (
    <main aria-label="Hidden chats" className="mx-auto max-w-4xl space-y-6 p-6">
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <header>
        {/* TODO: missing i18n key */}
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Hidden chats</h1>
        {/* TODO: missing i18n key */}
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">Restore chats hidden from the sidebar and chat search.</p>
      </header>
      <HiddenChatsPanel onNotice={setNotice} />
    </main>
  )
}

function HiddenChatsPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [page, setPage] = useState(1)
  const hiddenChats = useQuery({
    queryKey: ["hidden-chats", page],
    queryFn: () => fetchHiddenChats(page),
    placeholderData: (previousData) => previousData
  })
  const unhide = useMutation({
    mutationFn: (chat: HiddenChatRecord) => unhideChat(chat.app_unhide_path),
    onSuccess: (payload) => {
      onNotice(payload.message || "Chat restored.")
      void queryClient.invalidateQueries({ queryKey: ["hidden-chats"] })
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }
  })

  const payload = hiddenChats.data
  const chats = payload?.chats || []
  const total = payload?.total || 0
  const currentPage = payload?.page || page
  const perPage = payload?.per_page || 20
  const totalPages = Math.max(payload?.total_pages || 1, 1)
  const firstItem = total > 0 ? (currentPage - 1) * perPage + 1 : 0
  const lastItem = Math.min(currentPage * perPage, total)

  return (
    <section className="rounded border border-gray-200 bg-white p-5 dark:border-gray-700 dark:bg-gray-900">
      <div>
        {/* TODO: missing i18n key */}
        {hiddenChats.isPending ? <PanelMessage>Loading hidden chats...</PanelMessage> : null}
        {/* TODO: missing i18n key */}
        {hiddenChats.isError ? <PanelMessage tone="error">{errorMessage(hiddenChats.error, "Unable to load hidden chats.")}</PanelMessage> : null}
        {/* TODO: missing i18n key */}
        {unhide.isError ? <PanelMessage tone="error">{errorMessage(unhide.error, "Unable to restore chat.")}</PanelMessage> : null}
        {/* TODO: missing i18n key */}
        {payload && chats.length === 0 ? <PanelMessage>No hidden chats.</PanelMessage> : null}
        {payload && chats.length > 0 ? (
          <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700">
            <div className="divide-y divide-gray-200 dark:divide-gray-700">
              {chats.map((chat) => (
                <div className="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[1fr_auto] sm:items-center" key={chat.id}>
                  <div className="min-w-0">
                    <div className="truncate font-medium text-gray-900 dark:text-gray-100">{chat.title || chat.repository?.slug || t("new_title")}</div>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
                      {/* TODO: missing i18n key */}
                      <span>{chat.repository?.slug || "General"}</span>
                      {/* TODO: missing i18n key */}
                      <span>Hidden {formatDateTime(chat.hidden_at)}</span>
                    </div>
                  </div>
                  <button
                    className="rounded border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
                    disabled={unhide.isPending && unhide.variables?.id === chat.id}
                    onClick={() => unhide.mutate(chat)}
                    type="button"
                  >
                    {/* TODO: missing i18n key */}
                    {unhide.isPending && unhide.variables?.id === chat.id ? "Restoring..." : "Unhide"}
                  </button>
                </div>
              ))}
            </div>
          </div>
        ) : null}
      </div>

      {payload && totalPages > 1 ? (
        <div className="mt-4 flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
          {/* TODO: missing i18n key */}
          <span>Showing {firstItem}-{lastItem} of {total}</span>
          {/* TODO: missing i18n key */}
          <div className="flex gap-2">
            {currentPage > 1 ? (
              <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800" onClick={() => setPage((current) => Math.max(current - 1, 1))} type="button">Previous</button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">Previous</span>
            )}
            {currentPage < totalPages ? (
              <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800" onClick={() => setPage((current) => current + 1)} type="button">Next</button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">Next</span>
            )}
          </div>
        </div>
      ) : null}
    </section>
  )
}

function chatTitle(chat: HiddenChatRecord) {
  return chat.title || chat.repository?.slug || "New chat"
}

function formatDateTime(value: string | null) {
  if (!value) return "unknown"

  return new Intl.DateTimeFormat(undefined, {
    dateStyle: "medium",
    timeStyle: "short"
  }).format(new Date(value))
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function errorMessage(error: Error, fallback: string) {
  if (error instanceof ApiError) return error.message
  return fallback
}

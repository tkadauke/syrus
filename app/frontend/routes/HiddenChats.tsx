import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { formatRelativeDate } from "../lib/relativeTime"
import { useState } from "react"
import { fetchHiddenChats, unhideChat, type HiddenChatRecord } from "../api/chats"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

export function HiddenChatsRoute() {
  const [notice, setNotice] = useState<string | null>(null)
  const { t } = useT("chat")

  return (
    <main aria-label={t("aria_hidden_chats")} className="mx-auto max-w-4xl space-y-6 p-6">
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t('hidden.heading')}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t('hidden.description')}</p>
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
        {hiddenChats.isPending ? <PanelMessage>{t('hidden.loading')}</PanelMessage> : null}
        {hiddenChats.isError ? <PanelMessage tone="error">{errorMessage(hiddenChats.error, t('hidden.error_load'))}</PanelMessage> : null}
        {unhide.isError ? <PanelMessage tone="error">{errorMessage(unhide.error, t('hidden.error_restore'))}</PanelMessage> : null}
        {payload && chats.length === 0 ? <PanelMessage>{t('hidden.empty')}</PanelMessage> : null}
        {payload && chats.length > 0 ? (
          <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700">
            <div className="divide-y divide-gray-200 dark:divide-gray-700">
              {chats.map((chat) => (
                <div className="grid gap-3 px-4 py-3 text-sm sm:grid-cols-[1fr_auto] sm:items-center" key={chat.id}>
                  <div className="min-w-0">
                    <div className="truncate font-medium text-gray-900 dark:text-gray-100">{chat.title || chat.repository?.slug || t("new_title")}</div>
                    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
                      <span>{chat.repository?.slug || t('hidden.general')}</span>
                      <span>{t('hidden.hidden_at', { date: chat.hidden_at ? formatRelativeDate(new Date(chat.hidden_at)) : "-" })}</span>
                    </div>
                  </div>
                  <button
                    className="rounded border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
                    disabled={unhide.isPending && unhide.variables?.id === chat.id}
                    onClick={() => unhide.mutate(chat)}
                    type="button"
                  >
                    {unhide.isPending && unhide.variables?.id === chat.id ? t('hidden.restoring') : t('hidden.unhide')}
                  </button>
                </div>
              ))}
            </div>
          </div>
        ) : null}
      </div>

      {payload && totalPages > 1 ? (
        <div className="mt-4 flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
          <span>{t('hidden.showing', { first: firstItem, last: lastItem, total })}</span>
          <div className="flex gap-2">
            {currentPage > 1 ? (
              <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800" onClick={() => setPage((current) => Math.max(current - 1, 1))} type="button">{t('hidden.previous')}</button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">{t('hidden.previous')}</span>
            )}
            {currentPage < totalPages ? (
              <button className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800" onClick={() => setPage((current) => current + 1)} type="button">{t('hidden.next')}</button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">{t('hidden.next')}</span>
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



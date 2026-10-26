import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { createChatShare, fetchChatShares, removeChatShare, type ChatSharePerson } from "../../api/chats"
import { Avatar } from "../../components/Avatar"
import { CloseIcon } from "../../components/CloseIcon"
import { Input } from "../../components/Input"
import { Surface } from "../../components/ui"
import { useT } from "../../hooks/useT"

export function ChatShares({ chatId }: { chatId: number }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [open, setOpen] = useState(false)
  const [search, setSearch] = useState("")
  const queryKey = ["chat-shares", chatId, search]
  const shares = useQuery({ queryKey, queryFn: () => fetchChatShares(chatId, search), enabled: open })

  async function add(person: ChatSharePerson) {
    await createChatShare(chatId, person.user_id, search)
    await queryClient.invalidateQueries({ queryKey: ["chat-shares", chatId] })
  }

  async function remove(person: ChatSharePerson) {
    if (person.id == null) return
    await removeChatShare(chatId, person.id)
    await queryClient.invalidateQueries({ queryKey: ["chat-shares", chatId] })
  }

  return (
    <>
      <button
        className="rounded-full border border-border px-2.5 py-1 text-xs font-medium text-text-secondary hover:bg-surface-raised"
        onClick={() => setOpen(true)}
        type="button"
      >
        {t("chat_shares.share")}
      </button>
      {open ? (
        <div className="fixed inset-0 z-40 flex items-center justify-center bg-overlay p-4" onClick={() => setOpen(false)} role="presentation">
          <Surface
            aria-modal="true"
            className="w-full max-w-md shadow-xl"
            onClick={(event) => event.stopPropagation()}
            padding="none"
            role="dialog"
            variant="raised"
          >
            <header className="flex items-center justify-between border-b border-border px-4 py-3">
              <h2 className="font-semibold">{t("chat_shares.title")}</h2>
              <button aria-label={t("cancel")} onClick={() => setOpen(false)} type="button">
                <CloseIcon className="h-4 w-4" />
              </button>
            </header>
            <div className="p-3">
              <Input onChange={(event) => setSearch(event.target.value)} placeholder={t("chat_shares.search")} value={search} />
            </div>
            <div className="max-h-80 space-y-1 overflow-y-auto px-3 pb-3">
              {shares.data?.shares.map((person) => (
                <PersonRow action={t("chat_shares.remove")} key={`share-${person.id}`} person={person} onClick={() => remove(person)} />
              ))}
              {shares.data?.candidates.map((person) => (
                <PersonRow action={t("chat_shares.add")} key={`candidate-${person.user_id}`} person={person} onClick={() => add(person)} />
              ))}
              {shares.isPending ? <p className="text-sm text-text-secondary">{t("chat_shares.loading")}</p> : null}
            </div>
          </Surface>
        </div>
      ) : null}
    </>
  )
}

function PersonRow({ person, action, onClick }: { person: ChatSharePerson; action: string; onClick: () => void }) {
  const { t } = useT("chat")
  return (
    <div className="flex items-center gap-2 rounded px-2 py-2 hover:bg-surface-raised">
      <Avatar avatarUrl={person.avatar_url} name={person.name} size="sm" />
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm">
          {person.name} <span className="text-text-secondary">@{person.handle}</span>
        </p>
        {!person.repository_access ? <p className="text-xs text-warning-text">{t("chat_shares.repository_warning")}</p> : null}
      </div>
      <button className="text-xs font-medium text-brand" onClick={onClick} type="button">
        {action}
      </button>
    </div>
  )
}

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { createChatShare, deleteChatShare, fetchChatShareCandidates, fetchChatShares } from "../../api/chats"
import { Button } from "../../components/Button"
import { Input } from "../../components/Input"
import { Modal } from "../../components/Modal"
import { useT } from "../../hooks/useT"

export function ChatShareDialog({ chatId, open, onClose }: { chatId: number; open: boolean; onClose: () => void }) {
  const { t } = useT("chat")
  const client = useQueryClient()
  const [query, setQuery] = useState("")
  const sharesKey = ["chat-shares", chatId]
  const shares = useQuery({ queryKey: sharesKey, queryFn: () => fetchChatShares(chatId), enabled: open })
  const candidates = useQuery({ queryKey: ["chat-share-candidates", chatId, query], queryFn: () => fetchChatShareCandidates(chatId, query), enabled: open })
  const add = useMutation({
    mutationFn: (target: { target_type: string; target_id: number }) => createChatShare(chatId, target),
    onSuccess: (data) => client.setQueryData(sharesKey, data)
  })
  const remove = useMutation({ mutationFn: (shareId: number) => deleteChatShare(chatId, shareId), onSuccess: (data) => client.setQueryData(sharesKey, data) })

  return (
    <Modal
      open={open}
      onClose={onClose}
      label={t("share_dialog_title")}
      className="w-full max-w-lg rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]"
    >
      <h2 className="text-lg font-semibold text-text-primary">{t("share_dialog_title")}</h2>
      <p className="mt-1 text-sm text-text-secondary">{t("share_dialog_description")}</p>
      <Input className="mt-4 w-full" value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t("share_dialog_search")} />
      <div className="mt-4 space-y-2">
        {shares.data?.shares.map((person) => (
          <div className="flex items-center justify-between gap-3" key={person.id}>
            <div>
              <div className="text-sm font-medium text-text-primary">
                {person.name} <span className="text-text-muted">@{person.handle}</span>
              </div>
              {person.repository_access_warning ? <div className="text-xs text-warning">{t("share_repository_warning")}</div> : null}
            </div>
            <Button size="sm" variant="secondary" disabled={remove.isPending} onClick={() => remove.mutate(person.id!)}>
              {t("share_remove")}
            </Button>
          </div>
        ))}
        {candidates.data?.targets.map((person) => (
          <div className="flex items-center justify-between gap-3" key={`${person.target_type}-${person.target_id}`}>
            <div>
              <div className="text-sm font-medium text-text-primary">
                {person.name} <span className="text-text-muted">@{person.handle}</span>
              </div>
              {person.repository_access_warning ? <div className="text-xs text-warning">{t("share_repository_warning")}</div> : null}
            </div>
            <Button size="sm" disabled={add.isPending} onClick={() => add.mutate({ target_type: person.target_type, target_id: person.target_id })}>
              {t("share_add")}
            </Button>
          </div>
        ))}
      </div>
      <div className="mt-5 flex justify-end">
        <Button variant="secondary" onClick={onClose}>
          {t("share_close")}
        </Button>
      </div>
    </Modal>
  )
}

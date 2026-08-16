import { useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useRef, useState } from "react"
import { fetchInvitableUsers, type InvitableUser } from "../../api/chats"
import { CloseIcon } from "../../components/CloseIcon"
import { useT } from "../../hooks/useT"
import { primaryButton, secondaryButton } from "./utils"

// Reused for both entry points that need to pick Syrus users to add to a
// group chat: the "New group chat" creation flow (no excludeChatId) and the
// chat header's "Add participant" action (excludeChatId filters out users
// already in that chat, server-side).
export function ParticipantPickerModal({
  title,
  confirmLabel,
  excludeChatId,
  submitting = false,
  error,
  onCancel,
  onConfirm
}: {
  title: string
  confirmLabel: string
  excludeChatId?: number | string | null
  submitting?: boolean
  error?: string | null
  onCancel: () => void
  onConfirm: (userIds: number[]) => void
}) {
  const { t } = useT("chat")
  const [query, setQuery] = useState("")
  const [selectedIds, setSelectedIds] = useState<number[]>([])
  const inputRef = useRef<HTMLInputElement | null>(null)

  const invitableQuery = useQuery({
    queryKey: ["invitable-users", excludeChatId ?? null],
    queryFn: () => fetchInvitableUsers(excludeChatId)
  })
  const users = invitableQuery.data ?? []

  const filteredUsers = useMemo<InvitableUser[]>(() => {
    if (!query.trim()) return users
    const lower = query.toLowerCase()
    return users.filter((user) => user.name.toLowerCase().includes(lower))
  }, [users, query])

  useEffect(() => {
    inputRef.current?.focus()

    function handleKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onCancel()
    }

    document.addEventListener("keydown", handleKeyDown)
    return () => document.removeEventListener("keydown", handleKeyDown)
  }, [onCancel])

  function toggleUser(userId: number) {
    setSelectedIds((current) => current.includes(userId) ? current.filter((id) => id !== userId) : [...current, userId])
  }

  function submit() {
    if (selectedIds.length === 0 || submitting) return
    onConfirm(selectedIds)
  }

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-gray-950/35 p-4" onClick={onCancel} role="presentation">
      <section aria-labelledby="participant-picker-title" aria-modal="true" className="w-full max-w-md rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-900" onClick={(event) => event.stopPropagation()} role="dialog">
        <header className="flex items-center justify-between border-b border-gray-200 px-4 py-3 dark:border-gray-700">
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="participant-picker-title">{title}</h2>
          <button
            aria-label={t("cancel")}
            className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            onClick={onCancel}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="border-b border-gray-100 p-2 dark:border-gray-800">
          <input
            className="w-full rounded border border-gray-200 bg-white px-2.5 py-1.5 text-sm placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500"
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("group_picker_search_placeholder")}
            ref={inputRef}
            type="text"
            value={query}
          />
        </div>
        <div className="max-h-[min(20rem,calc(100dvh-14rem))] overflow-y-auto p-2" role="listbox" aria-multiselectable="true">
          {invitableQuery.isPending ? (
            <div className="px-2 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("group_picker_loading")}</div>
          ) : filteredUsers.length === 0 ? (
            <div className="px-2 py-6 text-center text-sm text-gray-500 dark:text-gray-400">{t("group_picker_no_users")}</div>
          ) : (
            <div className="space-y-1">
              {filteredUsers.map((user) => {
                const selected = selectedIds.includes(user.id)
                return (
                  <button
                    aria-selected={selected}
                    className={`flex w-full items-center gap-2.5 rounded px-3 py-2 text-left text-sm ${selected ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-gray-50 dark:hover:bg-gray-800"}`}
                    key={user.id}
                    onClick={() => toggleUser(user.id)}
                    role="option"
                    type="button"
                  >
                    <input checked={selected} className="pointer-events-none h-4 w-4 rounded border-gray-300 text-blue-600 dark:border-gray-600" readOnly type="checkbox" />
                    <PickerAvatar avatarUrl={user.avatar_url} name={user.name} />
                    <span className="min-w-0 truncate text-gray-900 dark:text-gray-100">{user.name}</span>
                  </button>
                )
              })}
            </div>
          )}
        </div>
        <div className="flex items-center justify-between gap-2 border-t border-gray-100 px-4 py-3 dark:border-gray-800">
          <span className="text-xs text-gray-500 dark:text-gray-400">
            {t("group_picker_selected_count", { count: selectedIds.length })}
          </span>
          <div className="flex gap-2">
            <button className={secondaryButton()} disabled={submitting} onClick={onCancel} type="button">{t("cancel")}</button>
            <button className={primaryButton()} disabled={selectedIds.length === 0 || submitting} onClick={submit} type="button">{confirmLabel}</button>
          </div>
        </div>
        {error ? <p className="px-4 pb-3 text-sm text-red-700 dark:text-red-300">{error}</p> : null}
      </section>
    </div>
  )
}

function PickerAvatar({ avatarUrl, name }: { avatarUrl: string | null; name: string }) {
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "U"

  if (avatarUrl) {
    return <img alt="" className="h-6 w-6 shrink-0 rounded-full object-cover ring-1 ring-gray-200 dark:ring-gray-700" src={avatarUrl} />
  }

  return (
    <span aria-hidden="true" className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-gray-100 text-[10px] font-semibold text-gray-500 ring-1 ring-gray-200 dark:bg-gray-800 dark:text-gray-400 dark:ring-gray-700">
      {initials}
    </span>
  )
}

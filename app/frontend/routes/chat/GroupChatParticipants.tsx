import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { fetchBootstrap } from "../../api/bootstrap"
import { addChatParticipant, removeChatParticipant, type ChatParticipant, type ChatPayload } from "../../api/chats"
import { CloseIcon } from "../../components/CloseIcon"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { type ChatQueryKey } from "./constants"
import { ParticipantAvatar } from "./ParticipantAvatar"
import { ParticipantPickerModal } from "./ParticipantPicker"

// Participant management for the chat header of a `conversation_kind: "group"`
// chat: shows every current human participant as a chip, lets any current
// participant add another (reopens the invite picker filtered via
// excludeChatId) or remove one — including themselves, which reads as
// "Leave" and, on success, navigates the leaving user away from a chat they
// can no longer access (accessible_chat_sessions is derived from
// chat_participants server-side).
export function GroupChatParticipants({ payload, prefix, queryKey, onNotice }: { payload: ChatPayload; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const currentUserId = bootstrap.data?.current_user?.id
  const participants = payload.chat.participants || []
  const [pickerOpen, setPickerOpen] = useState(false)
  const [pickerSubmitting, setPickerSubmitting] = useState(false)
  const [pickerError, setPickerError] = useState<string | null>(null)
  const [pendingRemovalId, setPendingRemovalId] = useState<number | null>(null)

  function applyParticipants(next: ChatParticipant[]) {
    queryClient.setQueryData(queryKey, (current: ChatPayload | undefined) => current ? {
      ...current,
      chat: { ...current.chat, participants: next }
    } : current)
  }

  async function handleAddParticipants(userIds: number[]) {
    setPickerSubmitting(true)
    setPickerError(null)
    try {
      // Apply each addition to the cache as it lands, not only once the
      // whole batch succeeds — if a later id in the batch fails, everyone
      // added before it still shows up immediately instead of waiting for
      // the next `update_participants` broadcast.
      for (const userId of userIds) {
        const result = await addChatParticipant(payload.chat.id, userId)
        applyParticipants(result.participants)
      }
      setPickerOpen(false)
    } catch (error) {
      setPickerError(errorMessage(error, t("group_picker_add_error")))
    } finally {
      setPickerSubmitting(false)
    }
  }

  async function handleRemove(participant: ChatParticipant) {
    setPendingRemovalId(participant.id)
    try {
      const result = await removeChatParticipant(payload.chat.id, participant.id)
      applyParticipants(result.participants)
      if (participant.id === currentUserId) {
        onNotice(t("left_group_chat_notice"))
        navigate(`${prefix}/dashboard/jobs`)
      }
    } catch (error) {
      onNotice(errorMessage(error, t("group_picker_remove_error")))
    } finally {
      setPendingRemovalId(null)
    }
  }

  return (
    <div className="mt-2 flex flex-wrap items-center gap-1.5">
      {participants.map((participant) => {
        const isSelf = participant.id === currentUserId
        const actionLabel = isSelf ? t("leave_chat") : t("remove_participant", { name: participant.name })
        return (
          <span className="inline-flex items-center gap-1.5 rounded-full border border-gray-200 bg-gray-50 py-1 pl-1 pr-2 text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200" key={participant.id}>
            <ParticipantAvatar avatarUrl={participant.avatar_url} name={participant.name} />
            <span className="max-w-[8rem] truncate">{participant.name}</span>
            <button
              aria-label={actionLabel}
              className="rounded-full p-0.5 text-gray-400 hover:bg-gray-200 hover:text-gray-700 disabled:opacity-50 dark:hover:bg-gray-800 dark:hover:text-gray-200"
              disabled={pendingRemovalId === participant.id}
              onClick={() => handleRemove(participant)}
              title={actionLabel}
              type="button"
            >
              <CloseIcon className="h-3 w-3" />
            </button>
          </span>
        )
      })}
      <button
        className="rounded-full border border-dashed border-gray-300 px-2.5 py-1 text-xs font-medium text-gray-600 hover:border-gray-400 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
        onClick={() => { setPickerError(null); setPickerOpen(true) }}
        type="button"
      >
        + {t("add_participant")}
      </button>
      {pickerOpen ? (
        <ParticipantPickerModal
          confirmLabel={t("group_picker_add_button")}
          error={pickerError}
          excludeChatId={payload.chat.id}
          onCancel={() => setPickerOpen(false)}
          onConfirm={handleAddParticipants}
          submitting={pickerSubmitting}
          title={t("group_picker_title_add")}
        />
      ) : null}
    </div>
  )
}

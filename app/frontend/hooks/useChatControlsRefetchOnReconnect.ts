import { useQueryClient } from "@tanstack/react-query"
import { useEffect, useRef } from "react"
import { useConnectionContext } from "../lib/connectionContext"

export function useChatControlsRefetchOnReconnect(chatId: string) {
  const { reconnectAt } = useConnectionContext()
  const queryClient = useQueryClient()
  // Track last-seen reconnectAt so we only fire on new reconnects, not initial mount.
  const lastSeenReconnectAtRef = useRef(reconnectAt)

  useEffect(() => {
    if (reconnectAt === lastSeenReconnectAtRef.current) return
    lastSeenReconnectAtRef.current = reconnectAt
    if (reconnectAt == null) return
    void queryClient.refetchQueries({ queryKey: ["chats", chatId] })
  }, [reconnectAt, chatId, queryClient])
}

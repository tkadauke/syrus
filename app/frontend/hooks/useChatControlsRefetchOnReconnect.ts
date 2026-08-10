import { useQueryClient } from "@tanstack/react-query"
import { useEffect, useRef } from "react"
import { useConnectionContext } from "../lib/connectionContext"

export function useChatControlsRefetchOnReconnect(chatId: string, turnInFlight: boolean) {
  const { reconnectAt } = useConnectionContext()
  const queryClient = useQueryClient()
  // Track last-seen reconnectAt so we only fire on new reconnects, not initial mount.
  const lastSeenReconnectAtRef = useRef(reconnectAt)
  // Keep a ref to the latest turnInFlight so we read the current value inside the effect
  // without needing it as a dependency (we only want to fire on reconnect, not on every
  // turn state change).
  const turnInFlightRef = useRef(turnInFlight)
  useEffect(() => { turnInFlightRef.current = turnInFlight })

  useEffect(() => {
    if (reconnectAt === lastSeenReconnectAtRef.current) return
    lastSeenReconnectAtRef.current = reconnectAt
    if (reconnectAt == null || !turnInFlightRef.current) return
    void queryClient.refetchQueries({ queryKey: ["chats", chatId] })
  }, [reconnectAt, chatId, queryClient])
}

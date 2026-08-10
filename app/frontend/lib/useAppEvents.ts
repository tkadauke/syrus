import { useQueryClient } from "@tanstack/react-query"
import { useCallback, useEffect, useState } from "react"
import { subscribeToAppEvents } from "./actionCable"

export function useAppEvents() {
  const queryClient = useQueryClient()
  const [isDisconnected, setIsDisconnected] = useState(false)
  const [justReconnected, setJustReconnected] = useState(false)
  const [reconnectAt, setReconnectAt] = useState<number | null>(null)

  const onConnectionChange = useCallback((connected: boolean) => {
    setIsDisconnected(!connected)
    if (connected) {
      setJustReconnected(true)
      setReconnectAt(Date.now())
    }
  }, [])

  useEffect(() => {
    const subscription = subscribeToAppEvents(queryClient, undefined, onConnectionChange)
    return () => subscription.unsubscribe()
  }, [queryClient, onConnectionChange])

  return { isDisconnected, justReconnected, reconnectAt, clearReconnected: () => setJustReconnected(false) }
}

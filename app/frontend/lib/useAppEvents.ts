import { useQueryClient } from "@tanstack/react-query"
import { useCallback, useEffect, useState } from "react"
import { subscribeToAppEvents } from "./actionCable"

export function useAppEvents() {
  const queryClient = useQueryClient()
  const [isDisconnected, setIsDisconnected] = useState(false)
  const [justReconnected, setJustReconnected] = useState(false)

  const onConnectionChange = useCallback((connected: boolean) => {
    setIsDisconnected(!connected)
    if (connected) setJustReconnected(true)
  }, [])

  useEffect(() => {
    const subscription = subscribeToAppEvents(queryClient, undefined, onConnectionChange)
    return () => subscription.unsubscribe()
  }, [queryClient, onConnectionChange])

  return { isDisconnected, justReconnected, clearReconnected: () => setJustReconnected(false) }
}

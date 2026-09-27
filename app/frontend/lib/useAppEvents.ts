import { useQueryClient } from "@tanstack/react-query"
import { useCallback, useEffect, useRef, useState } from "react"
import { subscribeToAppEvents } from "./actionCable"
import type { ConnectionEvent, ConnectionEventKind, ConnectionStatus } from "./connectionContext"
import { setNativeNotificationCableSubscribed } from "./nativeNotifications"

const CONNECTION_WARNING_GRACE_MS = 4000
const MAX_CONNECTION_EVENTS = 8

export function useAppEvents() {
  const queryClient = useQueryClient()
  const [isDisconnected, setIsDisconnected] = useState(false)
  const [status, setStatus] = useState<ConnectionStatus>("connected")
  const [justReconnected, setJustReconnected] = useState(false)
  const [reconnectAt, setReconnectAt] = useState<number | null>(null)
  const [events, setEvents] = useState<ConnectionEvent[]>(() => [
    { id: Date.now(), kind: "connected", at: Date.now() }
  ])
  const warningTimerRef = useRef<number | null>(null)
  const statusRef = useRef<ConnectionStatus>("connected")
  const nextEventIdRef = useRef(1)

  const addEvent = useCallback((kind: ConnectionEventKind, at = Date.now()) => {
    setEvents((current) => [
      { id: nextEventIdRef.current++, kind, at },
      ...current
    ].slice(0, MAX_CONNECTION_EVENTS))
  }, [])

  const clearWarningTimer = useCallback(() => {
    if (warningTimerRef.current == null) return
    window.clearTimeout(warningTimerRef.current)
    warningTimerRef.current = null
  }, [])

  const updateStatus = useCallback((nextStatus: ConnectionStatus) => {
    statusRef.current = nextStatus
    setStatus(nextStatus)
  }, [])

  const onConnectionChange = useCallback((connected: boolean) => {
    clearWarningTimer()
    setIsDisconnected(!connected)
    if (connected) {
      const at = Date.now()
      const wasSurfaced = statusRef.current === "reconnecting"
      updateStatus("connected")
      setReconnectAt(at)
      if (wasSurfaced) {
        setJustReconnected(true)
        addEvent("reconnected", at)
      } else {
        addEvent("connected", at)
      }
      return
    }

    addEvent("disconnected")
    warningTimerRef.current = window.setTimeout(() => {
      updateStatus("reconnecting")
      addEvent("reconnecting")
      warningTimerRef.current = null
    }, CONNECTION_WARNING_GRACE_MS)
  }, [addEvent, clearWarningTimer, updateStatus])

  useEffect(() => {
    const subscription = subscribeToAppEvents(queryClient, undefined, onConnectionChange, setNativeNotificationCableSubscribed)
    return () => {
      clearWarningTimer()
      subscription.unsubscribe()
      setNativeNotificationCableSubscribed(false)
    }
  }, [clearWarningTimer, queryClient, onConnectionChange])

  return { isDisconnected, status, events, justReconnected, reconnectAt, clearReconnected: () => setJustReconnected(false) }
}

import { createContext, useContext } from "react"

export type ConnectionStatus = "connected" | "reconnecting"
export type ConnectionEventKind = "connected" | "disconnected" | "reconnecting" | "reconnected"

export type ConnectionEvent = {
  id: number
  kind: ConnectionEventKind
  at: number
}

type ConnectionContextValue = {
  isDisconnected: boolean
  status: ConnectionStatus
  reconnectAt: number | null
  events: ConnectionEvent[]
}

export const ConnectionContext = createContext<ConnectionContextValue>({
  isDisconnected: false,
  status: "connected",
  reconnectAt: null,
  events: []
})

export function useConnectionContext() {
  return useContext(ConnectionContext)
}

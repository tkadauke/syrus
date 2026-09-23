import { createContext, useContext } from "react"

type ConnectionContextValue = {
  isDisconnected: boolean
  reconnectAt: number | null
}

export const ConnectionContext = createContext<ConnectionContextValue>({ isDisconnected: false, reconnectAt: null })

export function useConnectionContext() {
  return useContext(ConnectionContext)
}

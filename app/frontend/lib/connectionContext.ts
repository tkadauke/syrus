import { createContext, useContext } from "react"

type ConnectionContextValue = {
  reconnectAt: number | null
}

export const ConnectionContext = createContext<ConnectionContextValue>({ reconnectAt: null })

export function useConnectionContext() {
  return useContext(ConnectionContext)
}

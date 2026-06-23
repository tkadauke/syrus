import { createContext, useContext } from "react"

export type LayoutVersion = "v1" | "v2"

const LayoutVersionContext = createContext<LayoutVersion>("v1")

export const LayoutVersionProvider = LayoutVersionContext.Provider

export function useLayoutVersion() {
  return useContext(LayoutVersionContext)
}

import { createContext, useContext, type ReactNode } from "react"

export type TimeZoneContextValue = { user: string; server: string }

const browserTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"
const TimeZoneContext = createContext<TimeZoneContextValue>({ user: browserTimeZone, server: browserTimeZone })

export function TimeZoneProvider({ value, children }: { value: TimeZoneContextValue; children: ReactNode }) {
  return <TimeZoneContext.Provider value={value}>{children}</TimeZoneContext.Provider>
}

export function useTimeZones() {
  return useContext(TimeZoneContext)
}

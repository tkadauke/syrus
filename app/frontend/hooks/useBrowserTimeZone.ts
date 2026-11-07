import { useEffect } from "react"
import type { BootstrapPayload } from "../api/bootstrap"
import { reportBrowserTimeZone } from "../api/userTimeZone"

export function useBrowserTimeZone(bootstrap: BootstrapPayload | undefined) {
  const userZone = bootstrap?.time_zones?.user

  useEffect(() => {
    if (!userZone || userZone.mode !== "automatic") return

    const browserZone = Intl.DateTimeFormat().resolvedOptions().timeZone
    if (!browserZone || browserZone === userZone.name) return

    void reportBrowserTimeZone(browserZone).catch(() => undefined)
  }, [userZone])
}

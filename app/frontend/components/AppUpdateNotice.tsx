import { useEffect, useState } from "react"
import { NoticeToast } from "./NoticeToast"
import { useT } from "../hooks/useT"
import { APP_UPDATE_EVENT, appUpdateIsDismissed, dismissAppUpdate, readAppUpdate, reloadForAppUpdate, type AppUpdate } from "../lib/appUpdate"

export function AppUpdateNotice() {
  const { t } = useT("common")
  const [update, setUpdate] = useState<AppUpdate | null>(() => readAppUpdate())
  const [, setClock] = useState(0)

  useEffect(() => {
    const refresh = (event: Event) => setUpdate((event as CustomEvent<AppUpdate>).detail ?? readAppUpdate())
    window.addEventListener(APP_UPDATE_EVENT, refresh)
    return () => window.removeEventListener(APP_UPDATE_EVENT, refresh)
  }, [])

  useEffect(() => {
    if (update?.kind !== "breaking") return
    const timer = window.setInterval(() => setClock((value) => value + 1), 1000)
    return () => window.clearInterval(timer)
  }, [update])

  if (!update || appUpdateIsDismissed(update)) return null
  const seconds = update.deadline == null ? null : Math.max(0, Math.ceil((update.deadline - Date.now()) / 1000))
  const message = update.kind === "breaking" ? t("app_update.breaking", { count: seconds }) : t("app_update.available")

  return (
    <NoticeToast
      persistent
      tone={update.kind === "breaking" ? "error" : "notice"}
      onDismiss={update.kind === "breaking" ? undefined : () => dismissAppUpdate(update.id)}
    >
      <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
        <span>{message}</span>
        <button className="font-semibold text-brand underline hover:no-underline" type="button" onClick={() => reloadForAppUpdate()}>
          {t(update.kind === "breaking" ? "app_update.reload_now" : "app_update.reload")}
        </button>
      </div>
    </NoticeToast>
  )
}

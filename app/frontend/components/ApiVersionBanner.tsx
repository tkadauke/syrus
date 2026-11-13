import { useEffect, useState } from "react"
import { useTranslation } from "react-i18next"
import { API_VERSION_MISMATCH_EVENT, readApiVersionMismatch, type ApiVersionMismatch } from "../api/version"
import { reloadPage } from "../lib/pageReload"
import { Button } from "./Button"

const BANNER_CLASS =
  "fixed inset-x-0 top-0 z-[100] flex items-center justify-center gap-3 border-b border-warning-border bg-warning-surface px-4 py-2 text-sm font-medium text-warning-text shadow"

export function ApiVersionBanner() {
  const { t } = useTranslation("common")
  const [mismatch, setMismatch] = useState<ApiVersionMismatch | null>(readApiVersionMismatch)

  useEffect(() => {
    const handleMismatch = (event: Event) => {
      setMismatch((event as CustomEvent<ApiVersionMismatch>).detail)
    }
    window.addEventListener(API_VERSION_MISMATCH_EVENT, handleMismatch)
    return () => window.removeEventListener(API_VERSION_MISMATCH_EVENT, handleMismatch)
  }, [])

  if (!mismatch) return null

  return (
    <div className={BANNER_CLASS} role="alert">
      <span>{t("shell.api_version_mismatch")}</span>
      <Button onClick={reloadPage} size="sm" variant="secondary">
        {t("route_error.reload_page")}
      </Button>
    </div>
  )
}

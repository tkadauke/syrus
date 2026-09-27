import { useState } from "react"
import { Link } from "react-router-dom"
import { CloseIcon } from "../components/CloseIcon"
import { Notice } from "../components/ui"
import { useT } from "../hooks/useT"
import { withRoutePrefix } from "../routes/dashboard/helpers"

type UrgentAttentionItems = {
  count: number
  dismissal_key: string
  path: string
}

const DISMISSAL_STORAGE_KEY = "syrus.urgent_attention_items_banner_dismissed"

function readDismissal(): string | null {
  try {
    return window.sessionStorage.getItem(DISMISSAL_STORAGE_KEY)
  } catch {
    return null
  }
}

function writeDismissal(token: string): void {
  try {
    window.sessionStorage.setItem(DISMISSAL_STORAGE_KEY, token)
  } catch {
    // sessionStorage can be unavailable in private or restricted browser contexts.
  }
}

export default function UrgentAttentionItemsBanner({ className = "", prefix = "", urgent_attention_items }: { className?: string; prefix?: string; urgent_attention_items?: UrgentAttentionItems }) {
  const { t } = useT("dashboard")
  const [dismissedToken, setDismissedToken] = useState<string | null>(() => readDismissal())

  if (!urgent_attention_items || urgent_attention_items.count <= 0) return null
  if (dismissedToken === urgent_attention_items.dismissal_key) return null

  return (
    <Notice className={className} contentClassName="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between" role="status" tone="warning">
      <div className="min-w-0">
        <span>{t("urgent_attention_items_summary", { count: urgent_attention_items.count })}</span>
        <div className="mt-1 text-xs">
          <Link className="font-medium underline underline-offset-2" to={withRoutePrefix(urgent_attention_items.path, prefix)}>
            {t("urgent_attention_items_cta")}
          </Link>
        </div>
      </div>
      <button
        aria-label={t("urgent_attention_items_dismiss")}
        className="shrink-0 text-warning hover:text-warning-text"
        onClick={() => {
          setDismissedToken(urgent_attention_items.dismissal_key)
          writeDismissal(urgent_attention_items.dismissal_key)
        }}
        type="button"
      >
        <CloseIcon />
      </button>
    </Notice>
  )
}

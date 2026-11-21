import { Link } from "react-router-dom"
import { Notice } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/lib/routing"

export default function ReviewDashboardNotice({ count, prefix = "" }: { count?: number; prefix?: string }) {
  const { t } = useT("review_workspace")
  if (!count) return null

  return (
    <Notice contentClassName="flex flex-wrap items-center justify-between gap-2" role="status">
      <span>{t("dashboard_ready", { count })}</span>
      <Link className="font-semibold text-brand underline underline-offset-2" to={withRoutePrefix("/review", prefix)}>
        {t("open_review")}
      </Link>
    </Notice>
  )
}

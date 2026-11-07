import { useT } from "@app/hooks/useT"
import type { ReviewContributionProps } from "@app/pluginReviewContributions"

export default function ReviewAudit({ payload }: ReviewContributionProps) {
  const { t } = useT("coworkers")
  const receipt = payload as { key?: string; version?: string | number }
  return (
    <p aria-label={t("review_audit.aria_label")} className="text-xs text-text-secondary">
      {t("review_audit.summary", { key: receipt.key || "—", version: receipt.version || "—" })}
    </p>
  )
}

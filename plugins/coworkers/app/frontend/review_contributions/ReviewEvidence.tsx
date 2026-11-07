import { useT } from "@app/hooks/useT"
import type { ReviewContributionProps } from "@app/pluginReviewContributions"

export default function ReviewEvidence({ payload }: ReviewContributionProps) {
  const { t } = useT("coworkers")
  const evidence = payload as { reviewer?: { label?: string }; verdict?: string }
  return (
    <p aria-label={t("review_evidence.aria_label")} className="text-xs text-text-secondary">
      {t("review_evidence.summary", { reviewer: evidence.reviewer?.label || "—", verdict: evidence.verdict || "—" })}
    </p>
  )
}

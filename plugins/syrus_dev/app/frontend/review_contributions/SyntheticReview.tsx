import type { ReviewContributionProps } from "@app/pluginReviewContributions"

export default function SyntheticReview({ payload, contribution }: ReviewContributionProps) {
  const value = payload as { label?: string }
  return <p aria-label={contribution.aria_label_key || undefined}>{value.label}</p>
}

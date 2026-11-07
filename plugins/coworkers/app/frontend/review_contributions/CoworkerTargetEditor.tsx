import type { ProviderRoutingReviewerTarget } from "@app/api/providerRoutingRules"
import { Select } from "@app/components/Select"
import { useT } from "@app/hooks/useT"
import type { ReviewContributionProps } from "@app/pluginReviewContributions"

export default function CoworkerTargetEditor({ payload, onChange }: ReviewContributionProps) {
  const { t } = useT("coworkers")
  const data = payload as { candidate?: { reviewer_target?: ProviderRoutingReviewerTarget | null }; targets?: ProviderRoutingReviewerTarget[] }
  const current = data.candidate?.reviewer_target
  return (
    <Select
      aria-label={t("review_target_editor.aria_label")}
      onChange={(event) => onChange?.(data.targets?.find((target) => `${target.type}:${target.reference}` === event.target.value) || null)}
      value={current ? `${current.type}:${current.reference}` : ""}
    >
      <option value="">{t("review_target_editor.none")}</option>
      {(data.targets || []).map((target) => (
        <option key={target.reference} value={`${target.type}:${target.reference}`}>
          {target.display.name}
        </option>
      ))}
    </Select>
  )
}

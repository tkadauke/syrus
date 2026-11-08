import { useT } from "@app/hooks/useT"

export default function ReviewSettingsSummary() {
  const { t } = useT("coworkers")
  return (
    <p aria-label={t("review_settings.aria_label")} className="text-xs text-text-secondary">
      {t("review_settings.description")}
    </p>
  )
}

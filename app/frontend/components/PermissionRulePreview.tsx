import type { RuleDraftPreview } from "../api/permissionRuleDrafts"
import { useT } from "../hooks/useT"

/**
 * Readable rendering of the canonical rule preview: the effective rule, its
 * exclusions, ceilings and representative match / non-match examples. Shared
 * by the rule editor and confirmed permission-management cards so a rule reads
 * the same wherever it is reviewed.
 */
export function PermissionRulePreview({ preview, headingLevel = 3 }: { preview: RuleDraftPreview; headingLevel?: 3 | 4 }) {
  const { t } = useT("settings")
  const Heading = `h${headingLevel}` as "h3" | "h4"
  if (!preview.valid || !preview.draft || !preview.summary) {
    return (
      <ul className="space-y-1 text-xs text-danger" role="alert">
        {preview.errors.map((error) => (
          <li key={error.code}>{error.message}</li>
        ))}
      </ul>
    )
  }
  const { draft, summary, ceiling, examples } = preview
  return (
    <div className="space-y-3 text-xs" data-testid="permission-rule-preview">
      <section>
        <Heading className="text-sm font-semibold text-text-primary">{t("permission_editor.effective_rule")}</Heading>
        <p className="mt-1 break-words text-text-secondary">{t(`permission_editor.policies.${draft.policy}`)}</p>
        <ul className="mt-1 list-disc space-y-0.5 pl-4 text-text-secondary">
          {summary.allows.map((line) => (
            <li className="break-words" key={line}>
              {line}
            </li>
          ))}
        </ul>
        {draft.expires_at ? (
          <p className="mt-1 text-text-muted">{t("permission_editor.expires_at", { time: new Date(draft.expires_at).toLocaleString() })}</p>
        ) : null}
      </section>
      <section>
        <Heading className="font-semibold text-text-primary">{t("permission_editor.exclusions")}</Heading>
        <ul className="mt-1 list-disc space-y-0.5 pl-4 text-text-secondary">
          {summary.excludes.map((line) => (
            <li className="break-words" key={line}>
              {line}
            </li>
          ))}
        </ul>
      </section>
      {ceiling ? (
        <section>
          <Heading className="font-semibold text-text-primary">{t("permission_editor.ceilings")}</Heading>
          <p className="mt-1 break-words text-text-secondary">
            {t("permission_editor.ceiling_autonomy", {
              autonomy: t(`permission_editor.autonomy.${ceiling.maximum_autonomy}`, { defaultValue: ceiling.maximum_autonomy })
            })}
            {ceiling.limited_by ? ` ${t("permission_editor.ceiling_limited_by", { layer: ceiling.limited_by.layer, policy: ceiling.limited_by.policy })}` : ""}
          </p>
        </section>
      ) : null}
      {examples ? (
        <section className="grid gap-3 sm:grid-cols-2">
          <div>
            <Heading className="font-semibold text-success">{t("permission_editor.matches")}</Heading>
            <ul className="mt-1 list-disc space-y-0.5 pl-4 text-text-secondary">
              {examples.matches.map((line) => (
                <li className="break-words" key={line}>
                  {line}
                </li>
              ))}
            </ul>
          </div>
          <div>
            <Heading className="font-semibold text-danger">{t("permission_editor.non_matches")}</Heading>
            <ul className="mt-1 list-disc space-y-0.5 pl-4 text-text-secondary">
              {examples.non_matches.map((line) => (
                <li className="break-words" key={line}>
                  {line}
                </li>
              ))}
            </ul>
          </div>
        </section>
      ) : null}
      {preview.warnings.length ? (
        <ul className="space-y-1 text-warning" role="status">
          {preview.warnings.map((warning) => (
            <li key={warning.code}>{warning.message}</li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}

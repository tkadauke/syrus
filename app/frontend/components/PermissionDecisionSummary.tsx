import type { ReactNode } from "react"
import type { PermissionPresentation } from "../api/permissionRequests"
import { useT } from "../hooks/useT"

export type TechnicalDetail = [label: string, value: unknown]

/** True for values that carry no information worth showing: blanks, `{}` and `[]`. */
export function hasDetailValue(value: unknown): boolean {
  if (value === null || value === undefined) return false
  if (typeof value === "string") return value.trim() !== "" && value.trim() !== "{}" && value.trim() !== "[]"
  if (Array.isArray(value)) return value.length > 0
  if (typeof value === "object") return Object.keys(value as object).length > 0
  return true
}

const asText = (value: unknown) => (typeof value === "string" ? value : Array.isArray(value) ? value.join(", ") : JSON.stringify(value, null, 2))

/**
 * The action phrase of a permission statement ("capture a screenshot" from
 * "Allow Syrus to capture a screenshot?"), used to word remembered scopes.
 */
export function permissionActionPhrase(statement?: string | null): string | null {
  if (!statement) return null
  const trimmed = statement.trim().replace(/[?.]$/, "")
  const match = /^allow\s+.+?\s+to\s+(.+)$/i.exec(trimmed)
  return (match ? match[1] : trimmed).trim() || null
}

/**
 * The shared decision hierarchy for chat authorization cards and the approval
 * inbox: a plain-language question, the decision-critical facts, then the
 * implementation metadata folded behind "Technical details".
 */
export function PermissionDecisionSummary({
  presentation,
  fallbackStatement,
  technical = [],
  extraTechnical,
  headingLevel = 3
}: {
  presentation?: PermissionPresentation
  fallbackStatement: string
  technical?: TechnicalDetail[]
  extraTechnical?: ReactNode
  headingLevel?: 2 | 3 | 4
}) {
  const { t } = useT("settings")
  const Heading = `h${headingLevel}` as "h2" | "h3" | "h4"
  const statement = presentation?.statement || fallbackStatement
  const question = /[?]$/.test(statement) ? statement : /^allow\b/i.test(statement) ? `${statement}?` : t("permission_decision.question", { action: statement })
  const requestedBy = [presentation?.agent, presentation?.origin].filter((value): value is string => Boolean(value)).join(" · ")
  const facts: Array<[string, string | undefined]> = [
    [t("permission_decision.what_happens"), presentation?.consequences?.join(", ")],
    [t("permission_decision.applies_to"), presentation?.scope],
    [t("permission_decision.requested_by"), requestedBy],
    [t("permission_decision.duration"), presentation?.requested_durations?.join(", ")]
  ]
  const visibleFacts = facts.filter((entry): entry is [string, string] => hasDetailValue(entry[1]))
  const details: TechnicalDetail[] = [...technical, [t("approval_inbox.why_required"), presentation?.why_approval_required]]
  const visibleDetails = details.filter(([, value]) => hasDetailValue(value))

  return (
    <div className="min-w-0 space-y-2" data-testid="permission-decision-summary">
      <Heading className="break-words text-base font-semibold text-text-primary">{question}</Heading>
      {visibleFacts.length ? (
        <dl className="grid min-w-0 gap-x-3 gap-y-1 text-sm sm:grid-cols-[auto_minmax(0,1fr)]">
          {visibleFacts.map(([label, value]) => (
            <div className="contents" key={label}>
              <dt className="font-medium text-text-muted">{label}</dt>
              <dd className="text-text-secondary [overflow-wrap:anywhere]">{value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {visibleDetails.length || extraTechnical ? (
        <details className="text-xs" data-testid="permission-technical-details">
          <summary className="cursor-pointer font-medium text-text-secondary">{t("permission_decision.technical_details")}</summary>
          <dl className="mt-1 min-w-0 space-y-1 text-text-secondary">
            {visibleDetails.map(([label, value]) => (
              <div className="min-w-0" key={label}>
                <dt className="font-medium text-text-muted">{label}</dt>
                <dd className="whitespace-pre-wrap font-mono [overflow-wrap:anywhere]">{asText(value)}</dd>
              </div>
            ))}
          </dl>
          {extraTechnical}
        </details>
      ) : null}
    </div>
  )
}

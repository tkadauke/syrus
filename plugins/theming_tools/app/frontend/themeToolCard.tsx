import type { ReactNode } from "react"
import i18n from "i18next"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import {
  Badge,
  CardShell,
  Disclosure,
  displayValue,
  EmptyState,
  EntityReference,
  InternalLink,
  Row,
  SectionLabel,
  StatePill
} from "@app/routes/chat/toolCardUi"

export type ThemeTokens = Record<string, string>
export type ContrastWarning = {
  text: string
  mode: string | null
  foreground: string | null
  background: string | null
  ratio: string | null
  requiredRatio: string | null
}
export type ThemePayload = {
  id: string
  slug: string | null
  name: string
  builtIn: boolean | null
  position: string | null
  colorTokens: Record<string, ThemeTokens>
  extendedTokens: Record<string, ThemeTokens>
  warnings: ContrastWarning[]
}

const TOKEN_ORDER = [
  "brand",
  "brand-emphasis",
  "surface",
  "surface-raised",
  "border",
  "text-primary",
  "text-secondary",
  "success",
  "warning",
  "danger",
  "info",
  "neutral",
  "on-brand"
]
const COLOR_MODES = ["light", "dark"] as const
export function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`theming_tools:${key}`, options)
}

function stringTokens(value: unknown): ThemeTokens | null {
  if (!isPlainObject(value)) return null
  const entries = Object.entries(value).flatMap(([key, raw]) => {
    const token = displayValue(raw)
    return token ? [[key, token] as const] : []
  })
  return entries.length ? Object.fromEntries(entries) : null
}

function parseTokens(value: unknown) {
  const colorTokens: Record<string, ThemeTokens> = {}
  const extendedTokens: Record<string, ThemeTokens> = {}
  if (!isPlainObject(value)) return { colorTokens, extendedTokens }
  Object.entries(value).forEach(([group, raw]) => {
    const tokens = stringTokens(raw)
    if (tokens) ((COLOR_MODES as readonly string[]).includes(group) ? colorTokens : extendedTokens)[group] = tokens
  })
  return { colorTokens, extendedTokens }
}

export function parseContrastWarning(value: unknown): ContrastWarning | null {
  const text = displayValue(value)
  if (!text) return null
  const match = text.match(
    /^(\S+)\s+(.+?)\s+(?:\(([^)]+)\)\s+)?on\s+(.+?)\s+(?:\(([^)]+)\)\s+)?has contrast\s+([\d.]+):1(?:,\s+needs at least\s+([\d.]+):1.*)?$/i
  )
  return {
    text,
    mode: match?.[1] ?? null,
    foreground: match ? `${match[2]}${match[3] ? ` (${match[3]})` : ""}` : null,
    background: match ? `${match[4]}${match[5] ? ` (${match[5]})` : ""}` : null,
    ratio: match?.[6] ?? null,
    requiredRatio: match?.[7] ?? null
  }
}

export function parseTheme(value: unknown): ThemePayload | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id) ?? displayValue(value.theme_id)
  const name = displayValue(value.name)
  if (!id || !name) return null
  const warnings = Array.isArray(value.contrast_warnings)
    ? value.contrast_warnings.flatMap((raw) => {
        const warning = parseContrastWarning(raw)
        return warning ? [warning] : []
      })
    : []
  return {
    id,
    slug: displayValue(value.slug),
    name,
    builtIn: typeof value.built_in === "boolean" ? value.built_in : null,
    position: displayValue(value.position),
    ...parseTokens(value.tokens),
    warnings
  }
}

export function parseThemeResult(context: ToolCardContext) {
  return parseTheme(context.parsedResult)
}
export function themeRows(context: ToolCardContext): ThemePayload[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.themes)) return null
  return parsed.themes.flatMap((raw) => {
    const theme = parseTheme(raw)
    return theme ? [theme] : []
  })
}
export function themeListSummary(context: ToolCardContext) {
  const rows = themeRows(context)
  return rows ? t("summary_theme_count", { count: rows.length }) : null
}

function errorWarnings(body: string) {
  const details = body.match(/Contrast check failed\s*--\s*fix these before [^:]+:\s*(.+)\.?$/is)?.[1]
  if (!details) return []
  return details
    .replace(/\.$/, "")
    .split(/;\s*/)
    .flatMap((raw) => {
      const warning = parseContrastWarning(raw)
      return warning ? [warning] : []
    })
}

function ContrastWarnings({ warnings }: { warnings: ContrastWarning[] }) {
  return (
    <div>
      <SectionLabel>{t("contrast_warnings")}</SectionLabel>
      <ul className="mt-1 space-y-1">
        {warnings.map((warning, index) => (
          <li className="min-w-0 rounded border border-warning-border bg-warning-bg px-2 py-1 text-xs text-warning-text" key={`${warning.text}-${index}`}>
            {warning.foreground && warning.background && warning.ratio ? (
              <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <span className="font-medium">{warning.mode}</span>
                <span className="break-words font-mono">
                  {warning.foreground} → {warning.background}
                </span>
                <span className="whitespace-nowrap">{t("contrast_ratio", { ratio: warning.ratio })}</span>
                {warning.requiredRatio ? (
                  <span className="whitespace-nowrap text-text-muted">{t("contrast_required", { ratio: warning.requiredRatio })}</span>
                ) : null}
              </div>
            ) : (
              <span className="break-words">{warning.text}</span>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}

function ErrorCard({ action, context }: { action: string; context: ToolCardContext }) {
  const warnings = errorWarnings(context.resultBody)
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={t("state_error")} tone="failure" />
        <span className="font-medium text-text-primary">{t("action_failed", { action })}</span>
      </div>
      {warnings.length ? (
        <ContrastWarnings warnings={warnings} />
      ) : (
        <div className="whitespace-pre-wrap break-words text-text-secondary">{context.resultBody || t("empty_error")}</div>
      )}
    </CardShell>
  )
}
export function errorSummary(action: string, context: ToolCardContext): string | null {
  return context.resultError ? t("action_failed", { action }) : null
}
export function renderError(action: string, context: ToolCardContext): ReactNode | null {
  return context.resultError ? <ErrorCard action={action} context={context} /> : null
}

function ThemeHeader({ theme, outcome, draft }: { theme: ThemePayload; outcome: string; draft: boolean }) {
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2">
      <StatePill state={outcome} tone={draft ? "info" : "success"} />
      <EntityReference href={`/design_system?theme_id=${encodeURIComponent(theme.id)}`} id={theme.id} kind="theme" wrap="nowrap" />
      {draft ? <Badge>{t("draft")}</Badge> : null}
      {theme.builtIn === true ? <Badge>{t("built_in")}</Badge> : theme.builtIn === false ? <Badge>{t("custom")}</Badge> : null}
      {theme.slug ? <Badge>{theme.slug}</Badge> : null}
    </div>
  )
}
function Swatch({ name, color }: { name: string; color: string }) {
  return (
    <div className="flex min-w-0 items-center gap-1.5">
      <span
        aria-label={`${name} ${color}`}
        className="h-4 w-4 shrink-0 rounded border border-black/10 dark:border-white/20"
        style={{ backgroundColor: color }}
      />
      <span className="truncate font-mono text-2xs text-text-secondary" title={`${name}: ${color}`}>
        {name}
      </span>
    </div>
  )
}
function ModeSwatches({ mode, tokens }: { mode: string; tokens: ThemeTokens }) {
  const entries = [
    ...TOKEN_ORDER.flatMap((key) => (tokens[key] ? [[key, tokens[key]] as const] : [])),
    ...Object.entries(tokens).filter(([key]) => !TOKEN_ORDER.includes(key))
  ]
  return entries.length ? (
    <div>
      <SectionLabel>{mode}</SectionLabel>
      <div className="mt-1 grid grid-cols-2 gap-1 sm:grid-cols-3">
        {entries.map(([key, color]) => (
          <Swatch color={color} key={`${mode}-${key}`} name={key} />
        ))}
      </div>
    </div>
  ) : null
}
function TokenGroups({ groups, label }: { groups: Record<string, ThemeTokens>; label: string }) {
  if (!Object.keys(groups).length) return null
  return (
    <Disclosure label={label}>
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
        {Object.entries(groups).map(([group, tokens]) => (
          <div className="min-w-0" key={group}>
            <SectionLabel>{group}</SectionLabel>
            {Object.entries(tokens).map(([key, value]) => (
              <div className="flex min-w-0 flex-wrap justify-between gap-x-3" key={key}>
                <dt className="break-words font-mono text-xs text-text-secondary">{key}</dt>
                <dd className="break-all font-mono text-xs text-text-primary">{value}</dd>
              </div>
            ))}
          </div>
        ))}
      </dl>
    </Disclosure>
  )
}

export function ThemeCard({
  theme,
  outcome,
  draft = false,
  overrides = {},
  details,
  linkLabel
}: {
  theme: ThemePayload
  outcome: string
  draft?: boolean
  overrides?: Record<string, ThemeTokens>
  details?: ReactNode
  linkLabel?: string
}) {
  const colors = Object.entries(theme.colorTokens)
  return (
    <CardShell>
      <ThemeHeader draft={draft} outcome={outcome} theme={theme} />
      <div className="break-words text-sm font-medium text-text-primary">{theme.name}</div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label={t("theme_id")} value={theme.id} />
        {theme.position != null ? <Row label={t("position")} value={theme.position} /> : null}
      </dl>
      {details}
      {draft || linkLabel ? (
        <InternalLink href={`/design_system?theme_id=${encodeURIComponent(theme.id)}`}>{linkLabel ?? t("open_preview")}</InternalLink>
      ) : null}
      {colors.length ? (
        <div className="grid gap-2 sm:grid-cols-2">
          {colors.map(([mode, tokens]) => (
            <ModeSwatches key={mode} mode={mode} tokens={tokens} />
          ))}
        </div>
      ) : (
        <EmptyState>{t("no_tokens")}</EmptyState>
      )}
      <TokenGroups groups={theme.extendedTokens} label={t("additional_tokens")} />
      <TokenGroups groups={overrides} label={t("input_overrides")} />
      {theme.warnings.length ? <ContrastWarnings warnings={theme.warnings} /> : null}
    </CardShell>
  )
}

export function inputTokenOverrides(input: Record<string, unknown> | undefined): Record<string, ThemeTokens> {
  if (!input) return {}
  return Object.fromEntries(
    Object.entries(input).flatMap(([group, raw]) => {
      const tokens = stringTokens(raw)
      return tokens ? [[group, tokens] as const] : []
    })
  )
}
export function MalformedThemeCard({ action }: { action: string }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={t("state_unreadable")} tone="warning" />
        <span className="font-medium text-text-primary">{t("unexpected_payload", { action })}</span>
      </div>
    </CardShell>
  )
}

export function ThemeListBody({ rows }: { rows: ThemePayload[] }) {
  if (!rows.length) return <EmptyState>{t("no_custom_themes")}</EmptyState>
  return (
    <div className="mt-1 overflow-x-auto rounded border border-border">
      <table className="w-full text-left text-xs">
        <thead className="bg-surface-raised text-2xs uppercase text-text-muted">
          <tr>
            <th className="px-2 py-1 font-semibold">{t("theme")}</th>
            <th className="px-2 py-1 font-semibold">{t("status")}</th>
            <th className="px-2 py-1 font-semibold">{t("palette")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-border bg-surface">
          {rows.map((theme) => (
            <tr key={theme.id}>
              <td className="px-2 py-1">
                <div className="font-medium text-text-primary">{theme.name}</div>
                <EntityReference href={`/design_system?theme_id=${encodeURIComponent(theme.id)}`} id={theme.id} kind="theme" slug={theme.slug} />
              </td>
              <td className="whitespace-nowrap px-2 py-1">
                <StatePill state={theme.builtIn ? t("built_in") : t("custom")} tone={theme.builtIn ? "neutral" : "info"} />
              </td>
              <td className="min-w-[12rem] px-2 py-1">
                <div className="flex flex-wrap gap-1">
                  {Object.entries(theme.colorTokens.light ?? {})
                    .slice(0, 6)
                    .map(([key, color]) => (
                      <span
                        aria-label={`${theme.name} ${key} ${color}`}
                        className="h-4 w-4 rounded border border-black/10 dark:border-white/20"
                        key={`${theme.id}-${key}`}
                        style={{ backgroundColor: color }}
                      />
                    ))}
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
export type DeleteThemeOutcome = { deletedThemeId: string; fallbackThemeId: string | null }
export function parseDeleteOutcome(context: ToolCardContext): DeleteThemeOutcome | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const id = displayValue(parsed.deleted_theme_id)
  return id ? { deletedThemeId: id, fallbackThemeId: displayValue(parsed.fallback_theme_id) } : null
}
export function DeleteThemeCard({ outcome }: { outcome: DeleteThemeOutcome }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={t("state_deleted")} tone="success" />
        <EntityReference id={outcome.deletedThemeId} kind="theme" />
      </div>
      {outcome.fallbackThemeId ? (
        <div className="min-w-0">
          <SectionLabel>{t("fallback_active_theme")}</SectionLabel>
          <EntityReference href={`/design_system?theme_id=${encodeURIComponent(outcome.fallbackThemeId)}`} id={outcome.fallbackThemeId} kind="theme" />
        </div>
      ) : null}
    </CardShell>
  )
}

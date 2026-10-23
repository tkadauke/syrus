import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import {
  errorSummary,
  inputTokenOverrides,
  MalformedThemeCard,
  parseThemeResult,
  renderError,
  Swatch,
  t,
  ThemeCard,
  themeFromResultField,
  type ThemePayload,
  type ThemeTokens
} from "../themeToolCard"

function priorTheme(context: ToolCardContext) {
  return themeFromResultField(context, "previous_theme", "previous", "before")
}

function ChangedToken({ group, name, value, oldValue }: { group: string; name: string; value: string; oldValue?: string }) {
  const isPaletteToken = group === "light" || group === "dark"
  return (
    <li className={["grid min-w-0 gap-1 rounded border border-border px-2 py-1.5", "sm:grid-cols-[minmax(8rem,1fr)_minmax(0,2fr)] sm:items-center"].join(" ")}>
      <span className="break-words font-mono text-xs text-text-secondary">
        {group}.{name}
      </span>
      <div className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
        {oldValue && isPaletteToken ? (
          <>
            <Swatch color={oldValue} name={t("old_value")} />
            <span aria-hidden="true" className="text-text-muted">
              →
            </span>
          </>
        ) : null}
        {oldValue && !isPaletteToken ? <span className="break-all font-mono text-2xs text-text-muted">{oldValue} →</span> : null}
        {isPaletteToken ? <Swatch color={value} name={t("new_value")} /> : null}
        <span className="break-all font-mono text-2xs text-text-muted">{value}</span>
      </div>
    </li>
  )
}

function ChangedFields({ context, previous }: { context: ToolCardContext; previous: ThemePayload | null }) {
  const input = context.input
  if (!input) return null
  const name = displayValue(input.name)
  const groups = inputTokenOverrides(input)
  const changes = Object.entries(groups).flatMap(([group, tokens]) => Object.entries(tokens).map(([token, value]) => ({ group, token, value })))
  if (!name && !changes.length) return null

  const previousTokens = (group: string): ThemeTokens | undefined => previous?.colorTokens[group] ?? previous?.extendedTokens[group]
  return (
    <section>
      <SectionLabel>{t("changed_fields")}</SectionLabel>
      {name ? (
        <div className="mt-1 flex min-w-0 flex-wrap items-baseline gap-x-2 rounded border border-border px-2 py-1.5 text-xs">
          <span className="font-medium text-text-secondary">{t("name")}</span>
          {previous?.name && previous.name !== name ? <span className="break-words text-text-muted">{previous.name} →</span> : null}
          <span className="break-words font-medium text-text-primary">{name}</span>
        </div>
      ) : null}
      {changes.length ? (
        <ul className="mt-1 grid min-w-0 gap-1 lg:grid-cols-2">
          {changes.map(({ group, token, value }) => (
            <ChangedToken group={group} key={`${group}-${token}`} name={token} oldValue={previousTokens(group)?.[token]} value={value} />
          ))}
        </ul>
      ) : null}
    </section>
  )
}

function structuredUpdateError(context: ToolCardContext) {
  if (!context.resultError) return null
  const body = context.resultBody
  if (/No custom theme .* owned by you was found/i.test(body)) {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={t("state_not_found")} tone="failure" />
          <span className="font-medium text-text-primary">{t("theme_not_available")}</span>
        </div>
        <p className="break-words text-sm text-text-secondary">{t("theme_not_available_detail")}</p>
      </CardShell>
    )
  }
  return null
}

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary(t("action_update"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return t("summary_updated", { name: theme.name, id: theme.id })
}

function renderExpanded(context: ToolCardContext) {
  const structuredError = structuredUpdateError(context)
  if (structuredError) return structuredError
  const error = renderError(t("action_update"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action={t("action_update")} />

  return (
    <div className="space-y-2">
      <ChangedFields context={context} previous={priorTheme(context)} />
      <ThemeCard outcome={t("state_updated")} theme={theme} />
    </div>
  )
}

const updateUserThemeToolCard: ToolCardRenderer = {
  toolName: "update_user_theme",
  argumentSummary(input) {
    const themeId = displayValue(input.theme_id)
    return themeId ? `THEME-${themeId}` : null
  },
  collapsedSummary,
  renderExpanded
}

export default updateUserThemeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "partial_palette_update",
    label: "Partial update with before and after swatches",
    input: { theme_id: 12, name: "Sunset Console v2", light: { brand: "#123456" }, dark: { brand: "#abcdef" } },
    parsedResult: {
      id: 12,
      name: "Sunset Console v2",
      built_in: false,
      tokens: { light: { brand: "#123456", surface: "#ffffff" }, dark: { brand: "#abcdef", surface: "#111827" } },
      previous_theme: { id: 12, name: "Sunset Console", tokens: { light: { brand: "#b6492e" }, dark: { brand: "#f59e0b" } } }
    }
  },
  {
    id: "not_found",
    label: "Theme not found or not owned",
    input: { theme_id: 99, name: "Nope" },
    resultError: true,
    resultBody: "No custom theme with id 99 owned by you was found."
  },
  {
    id: "contrast_error",
    label: "Contrast validation error",
    input: { theme_id: 12, light: { "text-primary": "#fefefe" } },
    resultError: true,
    resultBody:
      "Contrast check failed -- fix these before saving: light text-primary (#fefefe) on surface (#ffffff) has contrast 1.01:1, needs at least 4.5:1 for WCAG AA."
  },
  { id: "empty", label: "Empty result", resultBody: "" }
]

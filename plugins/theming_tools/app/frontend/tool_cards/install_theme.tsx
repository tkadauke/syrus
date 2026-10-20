import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { displayValue, EntityReference, Row } from "@app/routes/chat/toolCardUi"
import { errorSummary, inputTokenOverrides, MalformedThemeCard, parseThemeResult, renderError, t, ThemeCard } from "../themeToolCard"

function InstallDetails({ context }: { context: ToolCardContext }) {
  const sourceThemeId = displayValue(context.input?.theme_id)
  if (sourceThemeId) {
    return (
      <div className="grid min-w-0 gap-1 sm:grid-cols-2">
        <Row label={t("install_mode")} value={t("install_existing_theme")} />
        <div className="min-w-0">
          <div className="text-2xs font-medium uppercase tracking-wide text-text-muted">{t("source_theme")}</div>
          <EntityReference href={`/design_system?theme_id=${encodeURIComponent(sourceThemeId)}`} id={sourceThemeId} kind="theme" wrap="nowrap" />
        </div>
      </div>
    )
  }

  return (
    <div className="grid min-w-0 gap-1 sm:grid-cols-2">
      <Row label={t("install_mode")} value={t("install_new_theme")} />
      {displayValue(context.input?.name) ? <Row label={t("input_name")} value={displayValue(context.input?.name)!} /> : null}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const error = errorSummary(t("action_install"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return null

  return t("summary_installed", { name: theme.name, id: theme.id })
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError(t("action_install"), context)
  if (error) return error

  const theme = parseThemeResult(context)
  if (!theme) return <MalformedThemeCard action={t("action_install")} />

  return (
    <ThemeCard
      details={<InstallDetails context={context} />}
      linkLabel={t("open_theme_settings")}
      outcome={t("state_installed")}
      overrides={context.input?.theme_id ? {} : inputTokenOverrides(context.input)}
      theme={theme}
    />
  )
}

const installThemeToolCard: ToolCardRenderer = {
  toolName: "install_theme",
  collapsedSummary,
  renderExpanded
}

export default installThemeToolCard

export const examples: ToolCardExample[] = [
  {
    id: "existing_theme",
    label: "Install an existing theme",
    input: { theme_id: 12 },
    parsedResult: {
      id: 12,
      slug: "sunset-12",
      name: "Sunset Console",
      built_in: true,
      position: 4,
      tokens: { light: { brand: "#b6492e", surface: "#ffffff" }, dark: { brand: "#f59e0b", surface: "#111827" } }
    }
  },
  {
    id: "new_theme",
    label: "Create and install a new theme",
    input: { name: "Deep Work", light: { brand: "#2563eb" }, dark: { brand: "#60a5fa" }, shape: { "radius-control": "0.375rem" } },
    parsedResult: {
      id: 13,
      slug: "deep-work-1",
      name: "Deep Work",
      built_in: false,
      position: 5,
      tokens: { light: { brand: "#2563eb" }, dark: { brand: "#60a5fa" }, shape: { "radius-control": "0.375rem" } }
    }
  },
  {
    id: "contrast_error",
    label: "Contrast validation error",
    input: { theme_id: 14 },
    resultError: true,
    resultBody:
      "Contrast check failed -- fix these before installing: light text-primary (#fefefe) on surface (#ffffff) has contrast 1.01:1, needs at least 4.5:1 for WCAG AA."
  },
  { id: "empty", label: "Empty result", resultBody: "" }
]

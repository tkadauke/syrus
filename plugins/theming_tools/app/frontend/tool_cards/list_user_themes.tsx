import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { errorSummary, MalformedThemeCard, renderError, t, themeListSummary, themeRows, ThemeListBody } from "../themeToolCard"

function collapsedSummary(context: ToolCardContext) {
  return errorSummary(t("action_list"), context) ?? themeListSummary(context)
}

function renderExpanded(context: ToolCardContext) {
  const error = renderError(t("action_list"), context)
  if (error) return error

  const rows = themeRows(context)
  if (!rows) return <MalformedThemeCard action={t("action_list")} />

  return <ThemeListBody rows={rows} />
}

const listUserThemesToolCard: ToolCardRenderer = {
  toolName: "list_user_themes",
  collapsedSummary,
  renderExpanded
}

export default listUserThemesToolCard

export const examples: ToolCardExample[] = [
  {
    id: "custom_themes",
    label: "Custom themes",
    parsedResult: {
      themes: [
        {
          id: 12,
          slug: "sunset-console",
          name: "Sunset Console",
          built_in: false,
          position: 4,
          tokens: {
            light: { brand: "#b6492e", surface: "#ffffff", "text-primary": "#111827" },
            dark: { brand: "#f59e0b", surface: "#111827", "text-primary": "#f3f4f6" },
            shape: { "radius-control": "0.375rem" }
          }
        }
      ]
    }
  },
  { id: "empty", label: "No custom themes", parsedResult: { themes: [] } },
  { id: "error", label: "Error", resultError: true, resultBody: "Unable to list themes." }
]

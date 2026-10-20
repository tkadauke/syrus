import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/routes/chat/toolRendering"
import deleteUserThemeToolCard from "./delete_user_theme"
import installThemeToolCard from "./install_theme"
import listUserThemesToolCard from "./list_user_themes"
import previewThemeToolCard from "./preview_theme"
import updateUserThemeToolCard from "./update_user_theme"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "preview_theme",
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

const tokens = {
  light: {
    brand: "#b6492e",
    "brand-emphasis": "#973b25",
    surface: "#ffffff",
    "surface-raised": "#f9fafb",
    border: "#e5e7eb",
    "text-primary": "#111827",
    "text-secondary": "#6b7280",
    success: "#047857",
    warning: "#b45309",
    danger: "#b91c1c",
    info: "#1d4ed8",
    neutral: "#374151",
    "on-brand": "#ffffff"
  },
  dark: {
    brand: "#f59e0b",
    "text-primary": "#f3f4f6",
    surface: "#111827"
  }
}

const theme = {
  id: 12,
  slug: "sunset-12",
  name: "Sunset Console",
  built_in: false,
  position: 4,
  tokens
}

describe("Theming Tools tool cards", () => {
  it("registers plugin-local card modules for all Theming Tools tools", () => {
    expect(pluginToolCardRendererFor("preview_theme")).not.toBeNull()
    expect(pluginToolCardRendererFor("install_theme")).not.toBeNull()
    expect(pluginToolCardRendererFor("list_user_themes")).not.toBeNull()
    expect(pluginToolCardRendererFor("update_user_theme")).not.toBeNull()
    expect(pluginToolCardRendererFor("delete_user_theme")).not.toBeNull()
  })

  it("renders preview_theme with draft id, status, swatches, and contrast warnings", () => {
    const parsedResult = {
      theme_id: 8,
      name: "Draft Mint",
      tokens,
      contrast_warnings: ["light text-secondary on surface has contrast 3.2:1"]
    }
    const cardContext = context({ parsedResult, input: { name: "Draft Mint", light: { brand: "#b6492e" }, shape: { "radius-control": "0.375rem" } } })

    expect(previewThemeToolCard.collapsedSummary?.(cardContext)).toBe("Previewed Draft Mint (THEME-8)")
    render(<>{previewThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("preview")).toBeInTheDocument()
    expect(screen.getByText("THEME-8")).toBeInTheDocument()
    expect(screen.getByText("draft")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open preview" })).toHaveAttribute("href", "/design_system?theme_id=8")
    expect(screen.getByText("Draft Mint")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #b6492e")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #f59e0b")).toBeInTheDocument()
    expect(screen.getByText("Contrast warnings")).toBeInTheDocument()
    expect(screen.getByText("text-secondary → surface")).toBeInTheDocument()
    expect(screen.getByText("3.2:1")).toBeInTheDocument()
    expect(screen.getByText("Input overrides")).toBeInTheDocument()
  })

  it("renders non-color token groups as text in a collapsed disclosure", () => {
    // Theme#public_payload always backfills shape/shadow/spacing/density/typography
    // (Theme#tokens_with_defaults) alongside light/dark -- install_theme and
    // update_user_theme return this full shape on every call, not just when a
    // caller explicitly overrides a non-color group.
    const tokensWithExtendedGroups = {
      ...tokens,
      shape: { "radius-control": "0.375rem", "radius-panel": "0.5rem" },
      shadow: { "shadow-panel": "0 1px 2px rgb(0 0 0 / 0.06)" },
      spacing: { "space-page-x": "1.5rem" },
      density: { "control-height-sm": "2rem" },
      typography: { "font-sans": "Inter, ui-sans-serif, system-ui, sans-serif" }
    }
    const cardContext = context({
      toolName: "install_theme",
      parsedResult: { ...theme, tokens: tokensWithExtendedGroups }
    })

    render(<>{installThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("light")).toBeInTheDocument()
    expect(screen.getByText("dark")).toBeInTheDocument()
    ;["shape", "shadow", "spacing", "density", "typography"].forEach((group) => {
      expect(screen.getByText(group)).toBeInTheDocument()
    })
    expect(screen.queryByLabelText(/radius-control/)).not.toBeInTheDocument()
    expect(screen.getByText("radius-control")).toBeInTheDocument()
    expect(screen.getByText("font-sans")).toBeInTheDocument()
  })

  it("renders install_theme as an installed theme with built-in/custom status and palette details", () => {
    const cardContext = context({ toolName: "install_theme", parsedResult: { ...theme, built_in: true } })

    expect(installThemeToolCard.collapsedSummary?.(cardContext)).toBe("Installed Sunset Console (THEME-12)")
    render(<>{installThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("installed")).toBeInTheDocument()
    expect(screen.getByText("built in")).toBeInTheDocument()
    expect(screen.getByText("sunset-12")).toBeInTheDocument()
    expect(screen.getByText("Theme ID")).toBeInTheDocument()
  })

  it("renders a partial update with changed fields, optional old swatches, and both resulting palettes", () => {
    const cardContext = context({
      toolName: "update_user_theme",
      input: { theme_id: 12, name: "Sunset Console v2", light: { brand: "#123456" }, dark: { brand: "#abcdef" } },
      parsedResult: {
        ...theme,
        name: "Sunset Console v2",
        tokens: { ...tokens, light: { ...tokens.light, brand: "#123456" }, dark: { ...tokens.dark, brand: "#abcdef" } },
        previous_theme: { ...theme }
      }
    })

    expect(updateUserThemeToolCard.collapsedSummary?.(cardContext)).toBe("Updated Sunset Console v2 (THEME-12)")
    render(<>{updateUserThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("updated")).toBeInTheDocument()
    expect(screen.getByText("Changed fields")).toBeInTheDocument()
    expect(screen.getByText("Sunset Console →")).toBeInTheDocument()
    expect(screen.getByText("light.brand")).toBeInTheDocument()
    expect(screen.getByText("dark.brand")).toBeInTheDocument()
    expect(screen.getByLabelText("old #b6492e")).toBeInTheDocument()
    expect(screen.getByLabelText("new #123456")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #123456")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #abcdef")).toBeInTheDocument()
  })

  it("renders an update without invented old values and handles malformed payloads", () => {
    const cardContext = context({
      toolName: "update_user_theme",
      input: { theme_id: 12, light: { brand: "#123456" } },
      parsedResult: { ...theme, tokens: { ...tokens, light: { ...tokens.light, brand: "#123456" } } }
    })
    render(<>{updateUserThemeToolCard.renderExpanded(cardContext)}</>)
    expect(screen.queryByLabelText(/^old /)).not.toBeInTheDocument()
    expect(screen.getByLabelText("new #123456")).toBeInTheDocument()

    render(<>{updateUserThemeToolCard.renderExpanded(context({ toolName: "update_user_theme", parsedResult: { id: 12, tokens } }))}</>)
    expect(screen.getByText("Theme update returned an unexpected theme payload.")).toBeInTheDocument()
  })

  it("renders delete_user_theme outcome with fallback active theme", () => {
    const cardContext = context({
      toolName: "delete_user_theme",
      parsedResult: { deleted_theme_id: 12, fallback_theme_id: 1 }
    })

    expect(deleteUserThemeToolCard.collapsedSummary?.(cardContext)).toBe("Deleted theme THEME-12")
    render(<>{deleteUserThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("THEME-12")).toBeInTheDocument()
    expect(screen.getByText("Fallback active theme")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "THEME-1" })).toHaveAttribute("href", "/design_system?theme_id=1")
  })

  it("renders list_user_themes as a compact scannable list and skips malformed rows", () => {
    const cardContext = context({
      toolName: "list_user_themes",
      parsedResult: {
        themes: [theme, { oops: true }, { ...theme, id: 13, slug: "deep-work", name: "Deep Work", tokens: { light: { brand: "#2563eb" } } }]
      }
    })

    expect(listUserThemesToolCard.collapsedSummary?.(cardContext)).toBe("2 themes")
    render(<>{listUserThemesToolCard.renderExpanded(cardContext)}</>)

    const rows = screen.getAllByRole("row")
    expect(rows).toHaveLength(3)
    expect(within(rows[1]).getByText("Sunset Console")).toBeInTheDocument()
    expect(within(rows[2]).getByText("Deep Work")).toBeInTheDocument()
    expect(screen.getByLabelText("Sunset Console brand #b6492e")).toBeInTheDocument()
    expect(screen.getByLabelText("Deep Work brand #2563eb")).toBeInTheDocument()
  })

  it("renders empty list and tool error states without falling back to raw JSON", () => {
    const listContext = context({ toolName: "list_user_themes", parsedResult: { themes: [] } })
    expect(listUserThemesToolCard.collapsedSummary?.(listContext)).toBe("0 themes")
    render(<>{listUserThemesToolCard.renderExpanded(listContext)}</>)
    expect(screen.getByText("No custom themes yet.")).toBeInTheDocument()

    const errorContext = context({
      toolName: "preview_theme",
      resultBody:
        "Contrast check failed -- fix these before installing: light text-primary (#fefefe) on surface (#ffffff) has contrast 1.01:1, needs at least 4.5:1 for WCAG AA.",
      resultError: true,
      parsedResult: null
    })
    expect(previewThemeToolCard.collapsedSummary?.(errorContext)).toBe("Theme preview failed")
    render(<>{previewThemeToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("Theme preview failed")).toBeInTheDocument()
    expect(screen.getByText("text-primary (#fefefe) → surface (#ffffff)")).toBeInTheDocument()
    expect(screen.getByText("1.01:1")).toBeInTheDocument()
    expect(screen.getByText("needs 4.5:1")).toBeInTheDocument()
  })

  it("renders preview payloads from direct and MCP content envelopes", () => {
    const payload = { theme_id: 8, name: "Envelope Draft", tokens, contrast_warnings: [] }
    const envelopes = [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]

    envelopes.forEach((envelope) => {
      const cardContext = context({ parsedResult: normalizedToolCardParsedResult(envelope) })
      expect(previewThemeToolCard.collapsedSummary?.(cardContext)).toBe("Previewed Envelope Draft (THEME-8)")
    })
  })

  it("renders update payloads normalized from direct and MCP content envelopes", () => {
    const payload = { ...theme, name: "Envelope Update" }
    const envelopes = [payload, { structured_content: payload }, { content: [{ type: "text", text: JSON.stringify(payload) }] }]

    envelopes.forEach((envelope) => {
      const cardContext = context({ toolName: "update_user_theme", parsedResult: normalizedToolCardParsedResult(envelope) })
      expect(updateUserThemeToolCard.collapsedSummary?.(cardContext)).toBe("Updated Envelope Update (THEME-12)")
    })
  })

  it("renders structured not-found/ownership and contrast update errors", () => {
    const unavailable = context({
      toolName: "update_user_theme",
      resultError: true,
      resultBody: "No custom theme with id 99 owned by you was found.",
      parsedResult: null
    })
    render(<>{updateUserThemeToolCard.renderExpanded(unavailable)}</>)
    expect(screen.getByText("not found")).toBeInTheDocument()
    expect(screen.getByText("Theme not found or unavailable")).toBeInTheDocument()
    expect(screen.queryByText(unavailable.resultBody)).not.toBeInTheDocument()

    const contrast = context({
      toolName: "update_user_theme",
      resultError: true,
      resultBody:
        "Contrast check failed -- fix these before saving: dark text-primary (#111111) on surface (#000000) has contrast 1.1:1, needs at least 4.5:1 for WCAG AA.",
      parsedResult: null
    })
    render(<>{updateUserThemeToolCard.renderExpanded(contrast)}</>)
    expect(screen.getByText("text-primary (#111111) → surface (#000000)")).toBeInTheDocument()
    expect(screen.getByText("1.1:1")).toBeInTheDocument()
  })

  it("summarizes update arguments with the theme reference instead of raw JSON", () => {
    expect(updateUserThemeToolCard.argumentSummary?.({ theme_id: 12, light: { "text-primary": "#fefefe" } })).toBe("THEME-12")
  })

  it("renders an explicit preview card for an empty pending result", () => {
    const cardContext = context({ resultBody: "", parsedResult: null })
    render(<>{previewThemeToolCard.renderExpanded(cardContext)}</>)
    expect(screen.getByText("unreadable")).toBeInTheDocument()
    expect(screen.getByText("Theme preview returned an unexpected theme payload.")).toBeInTheDocument()
  })
})

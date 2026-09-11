import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { pluginToolCardRendererFor, type ToolCardContext } from "@app/pluginToolCards"
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
    const cardContext = context({ parsedResult })

    expect(previewThemeToolCard.collapsedSummary?.(cardContext)).toBe("Previewed Draft Mint (#8)")
    render(<>{previewThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("preview")).toBeInTheDocument()
    expect(screen.getByText("#8")).toBeInTheDocument()
    expect(screen.getByText("Draft Mint")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #b6492e")).toBeInTheDocument()
    expect(screen.getByLabelText("brand #f59e0b")).toBeInTheDocument()
    expect(screen.getByText("Contrast warnings")).toBeInTheDocument()
    expect(screen.getByText("light text-secondary on surface has contrast 3.2:1")).toBeInTheDocument()
  })

  it("renders install_theme as an installed theme with built-in/custom status and palette details", () => {
    const cardContext = context({ toolName: "install_theme", parsedResult: { ...theme, built_in: true } })

    expect(installThemeToolCard.collapsedSummary?.(cardContext)).toBe("Installed Sunset Console (#12)")
    render(<>{installThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("installed")).toBeInTheDocument()
    expect(screen.getByText("built in")).toBeInTheDocument()
    expect(screen.getByText("sunset-12")).toBeInTheDocument()
    expect(screen.getByText("Theme ID")).toBeInTheDocument()
  })

  it("renders update_user_theme outcome and handles malformed theme payloads without throwing", () => {
    const cardContext = context({ toolName: "update_user_theme", parsedResult: { ...theme, name: "Sunset Console v2" } })

    expect(updateUserThemeToolCard.collapsedSummary?.(cardContext)).toBe("Updated Sunset Console v2 (#12)")
    render(<>{updateUserThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("updated")).toBeInTheDocument()
    expect(screen.getByText("Sunset Console v2")).toBeInTheDocument()

    render(<>{updateUserThemeToolCard.renderExpanded(context({ toolName: "update_user_theme", parsedResult: { id: 12, tokens } }))}</>)
    expect(screen.getByText("Theme update returned an unexpected theme payload.")).toBeInTheDocument()
  })

  it("renders delete_user_theme outcome with fallback active theme", () => {
    const cardContext = context({
      toolName: "delete_user_theme",
      parsedResult: { deleted_theme_id: 12, fallback_theme_id: 1 }
    })

    expect(deleteUserThemeToolCard.collapsedSummary?.(cardContext)).toBe("Deleted theme #12")
    render(<>{deleteUserThemeToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("deleted")).toBeInTheDocument()
    expect(screen.getByText("#12")).toBeInTheDocument()
    expect(screen.getByText("Fallback active theme")).toBeInTheDocument()
    expect(screen.getByText("#1")).toBeInTheDocument()
  })

  it("renders list_user_themes as a compact scannable list and skips malformed rows", () => {
    const cardContext = context({
      toolName: "list_user_themes",
      parsedResult: {
        themes: [
          theme,
          { oops: true },
          { ...theme, id: 13, slug: "deep-work", name: "Deep Work", tokens: { light: { brand: "#2563eb" } } }
        ]
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
      toolName: "install_theme",
      resultBody: "Contrast check failed -- fix these before installing.",
      resultError: true,
      parsedResult: null
    })
    expect(installThemeToolCard.collapsedSummary?.(errorContext)).toBe("Theme install failed")
    render(<>{installThemeToolCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("Theme install failed")).toBeInTheDocument()
    expect(screen.getByText("Contrast check failed -- fix these before installing.")).toBeInTheDocument()
  })
})

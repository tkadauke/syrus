import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ThemePreviewModal } from "./ThemePreviewModal"

function dispatchThemePreview(detail: { chat_session_id: unknown; theme_id: number; path: string }) {
  window.dispatchEvent(new CustomEvent("syrus:theme-preview", { detail }))
}

describe("ThemePreviewModal", () => {
  it("renders nothing until a matching syrus:theme-preview event fires", () => {
    render(<ThemePreviewModal chatId="8" prefix="" />)

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("opens with an iframe pointed at the broadcast path when the chat id matches", async () => {
    render(<ThemePreviewModal chatId="8" prefix="" />)

    dispatchThemePreview({ chat_session_id: 8, theme_id: 42, path: "/design_system?theme_id=42" })

    const dialog = await screen.findByRole("dialog")
    const iframe = dialog.querySelector("iframe")
    expect(iframe).toHaveAttribute("src", "/design_system?theme_id=42")
  })

  it("ignores events for a different chat", () => {
    render(<ThemePreviewModal chatId="8" prefix="" />)

    dispatchThemePreview({ chat_session_id: 99, theme_id: 42, path: "/design_system?theme_id=42" })

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("route-prefixes the preview path for the desktop shell", async () => {
    render(<ThemePreviewModal chatId="8" prefix="/app-shell" />)

    dispatchThemePreview({ chat_session_id: 8, theme_id: 42, path: "/design_system?theme_id=42" })

    const dialog = await screen.findByRole("dialog")
    const iframe = dialog.querySelector("iframe")
    expect(iframe).toHaveAttribute("src", "/app-shell/design_system?theme_id=42")
  })

  it("closes when the close button is clicked", async () => {
    render(<ThemePreviewModal chatId="8" prefix="" />)

    dispatchThemePreview({ chat_session_id: 8, theme_id: 42, path: "/design_system?theme_id=42" })
    await screen.findByRole("dialog")

    fireEvent.click(screen.getByRole("button", { name: "Close" }))

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})

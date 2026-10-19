import { fireEvent, render, screen } from "@testing-library/react"
import i18n from "i18next"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import drawImageCard, { examples } from "./draw_image"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "draw_image", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("draw_image tool card", () => {
  it("renders every field and opens a downloadable full preview from a wrapped result", () => {
    const dataUrl = "data:image/png;base64,AA=="
    render(
      <>
        {drawImageCard.renderExpanded(
          context({
            input: { data_url: dataUrl, mime_type: "image/png", file_id: "input-file", x: 12, y: 24, width: 320, height: 180 },
            parsedResult: { result: { id: "image-1", file_id: "result-file", version: 7 } }
          })
        )}
      </>
    )
    expect(screen.getByRole("img", { name: "Whiteboard image" })).toHaveAttribute("src", dataUrl)
    for (const value of ["image-1", "v7", "input-file", "result-file", "image/png", "12", "24", "320", "180", "≈26 B"])
      expect(screen.getAllByText(value).length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole("button", { name: "Open result-file" }))
    const dialog = screen.getByRole("dialog", { name: "Whiteboard image" })
    expect(dialog).toHaveClass("max-h-full", "w-[min(960px,100vw-2rem)]")
    expect(screen.getAllByRole("img", { name: "Whiteboard image" })).toHaveLength(2)
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("href", dataUrl)
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("download")
  })

  it.each(["javascript:alert(1)", "file:///tmp/image.png", "data:text/html,<h1>no</h1>", "not a url"])("rejects unsafe image URL %s", (dataUrl) => {
    render(<>{drawImageCard.renderExpanded(context({ input: { data_url: dataUrl }, parsedResult: { id: "image-1", version: 1 } }))}</>)
    expect(screen.queryByRole("img")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Open/ })).not.toBeInTheDocument()
  })

  it("accepts provider-agnostic HTTPS image input", () => {
    render(
      <>{drawImageCard.renderExpanded(context({ input: { data_url: "https://cdn.example.com/image.webp" }, parsedResult: { id: "image-1", version: 1 } }))}</>
    )
    expect(screen.getByRole("img", { name: "Whiteboard image" })).toHaveAttribute("src", "https://cdn.example.com/image.webp")
  })

  it("handles a large data URL without rendering its payload as text", () => {
    const dataUrl = `data:image/png;base64,${"A".repeat(1024 * 1024)}`
    const { container } = render(
      <>{drawImageCard.renderExpanded(context({ input: { data_url: dataUrl }, parsedResult: { id: "large-image", version: 1 } }))}</>
    )
    expect(screen.getAllByText("≈1.0 MB")).toHaveLength(2)
    expect(container.textContent).not.toContain("A".repeat(100))
  })

  it("keeps failure and empty states and publishes examples", () => {
    const { unmount } = render(
      <>{drawImageCard.renderExpanded(context({ resultError: true, resultBody: "bad image", parsedResult: { message: "bad image" } }))}</>
    )
    expect(screen.getByText("Drew image failed")).toBeInTheDocument()
    unmount()
    render(<>{drawImageCard.renderExpanded(context())}</>)
    expect(screen.getByText("Waiting for a result")).toBeInTheDocument()
    expect(examples.map((example) => example.id)).toEqual(["image_preview", "pending", "failure"])
  })

  it("localizes image metadata and actions", async () => {
    await i18n.changeLanguage("de")
    try {
      const dataUrl = "data:image/png;base64,AA=="
      render(
        <>
          {drawImageCard.renderExpanded(
            context({
              input: { data_url: dataUrl, mime_type: "image/png", width: 20, height: 10, x: 1, y: 2 },
              parsedResult: { id: "image-1", file_id: "file-1", version: 2 }
            })
          )}
        </>
      )
      fireEvent.click(screen.getByRole("button", { name: "Open file-1" }))
      expect(screen.getByRole("link", { name: "Herunterladen" })).toBeInTheDocument()
      for (const label of ["Element-ID", "Version", "Datei-ID", "MIME-Typ", "Ungefaehre Groesse", "Abmessungen", "Position"])
        expect(screen.getAllByText(label).length).toBeGreaterThan(0)
    } finally {
      await i18n.changeLanguage("en")
    }
  })
})

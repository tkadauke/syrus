import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import browserCloseToolCard from "./browser_close"
import browserNavigateToolCard from "./browser_navigate"
import browserResizeToolCard from "./browser_resize"
import browserScreenshotToolCard from "./browser_screenshot"
import browserSnapshotToolCard from "./browser_snapshot"
import browserWaitForToolCard from "./browser_wait_for"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "browser_navigate",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("browser tool cards", () => {
  it("registers under the exact Browser MCP tool names", () => {
    const cards: ToolCardRenderer[] = [
      browserNavigateToolCard,
      browserSnapshotToolCard,
      browserScreenshotToolCard,
      browserResizeToolCard,
      browserWaitForToolCard,
      browserCloseToolCard
    ]

    expect(cards.map((card) => card.toolName)).toEqual([
      "browser_navigate",
      "browser_snapshot",
      "browser_screenshot",
      "browser_resize",
      "browser_wait_for",
      "browser_close"
    ])
  })

  it("summarizes and renders a successful navigation with page identity", () => {
    const resultBody = [
      "- Page URL: http://127.0.0.1:3001/dashboard",
      "- Page Title: Dashboard"
    ].join("\n")
    const toolContext = context({
      toolName: "browser_navigate",
      input: { url: "http://127.0.0.1:3001/dashboard" },
      resultBody
    })

    expect(browserNavigateToolCard.collapsedSummary?.(toolContext)).toBe(
      "Navigate http://127.0.0.1:3001/dashboard · Dashboard (http://127.0.0.1:3001/dashboard) · success"
    )

    render(<>{browserNavigateToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Navigate")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
    expect(screen.getByText("Dashboard")).toBeInTheDocument()
    expect(screen.getAllByText("http://127.0.0.1:3001/dashboard")).toHaveLength(2)
  })

  it("summarizes and renders navigation errors", () => {
    const toolContext = context({
      toolName: "browser_navigate",
      input: { url: "http://evil.example.com" },
      resultBody: "Error: Navigation to \"http://evil.example.com\" was blocked",
      resultError: true
    })

    expect(browserNavigateToolCard.collapsedSummary?.(toolContext)).toBe("Navigate http://evil.example.com · failed")

    render(<>{browserNavigateToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("error")).toBeInTheDocument()
    expect(screen.getByText("Navigation to \"http://evil.example.com\" was blocked")).toBeInTheDocument()
  })

  it("summarizes DOM snapshots with metadata and page identity", () => {
    const resultBody = [
      "- Page URL: http://127.0.0.1:3001/settings",
      "- Page Title: Settings",
      "- Page Snapshot:",
      "```yaml",
      "- button \"Save\" [ref=e1]",
      "```"
    ].join("\n")
    const toolContext = context({
      toolName: "browser_snapshot",
      resultBody
    })

    expect(browserSnapshotToolCard.collapsedSummary?.(toolContext)).toBe(
      "Snapshot · Settings (http://127.0.0.1:3001/settings) · success"
    )

    render(<>{browserSnapshotToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getAllByText("Snapshot")).toHaveLength(2)
    expect(screen.getByText("accessibility tree")).toBeInTheDocument()
    expect(screen.getByText("Settings")).toBeInTheDocument()
  })

  it("summarizes and renders screenshots from direct image content blocks", () => {
    const toolContext = context({
      toolName: "browser_screenshot",
      input: { element: "Hero panel", target: "e7" },
      parsedResult: [
        { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" }
      ]
    })

    expect(browserScreenshotToolCard.collapsedSummary?.(toolContext)).toBe("Screenshot Hero panel · Browser screenshot · success")

    render(<>{browserScreenshotToolCard.renderExpanded(toolContext)}</>)

    const image = screen.getByRole("img", { name: "Browser screenshot" })
    expect(image).toHaveAttribute("src", "data:image/png;base64,iVBORw0KGgo=")
    expect(image).toHaveClass("dark:bg-gray-950")
    expect(screen.getByText("image/png")).toBeInTheDocument()
  })

  it("renders screenshot previews from persisted artifact references", () => {
    const toolContext = context({
      toolName: "browser_screenshot",
      parsedResult: {
        content: [
          {
            type: "image",
            image_url: "/api/v1/app/chats/12/media/chat_images/3/file",
            title: "Checkout page",
            content_type: "image/png",
            byte_size: 2048
          }
        ],
        title: "Checkout",
        url: "http://127.0.0.1:3001/checkout",
        viewport: { width: 390, height: 844 }
      }
    })

    expect(browserScreenshotToolCard.collapsedSummary?.(toolContext)).toBe(
      "Screenshot · Checkout (http://127.0.0.1:3001/checkout) · success"
    )

    render(<>{browserScreenshotToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByRole("img", { name: "Checkout page" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(screen.getByText("Checkout")).toBeInTheDocument()
    expect(screen.getByText("http://127.0.0.1:3001/checkout")).toBeInTheDocument()
    expect(screen.getByText("390x844")).toBeInTheDocument()
    expect(screen.getByText("2 KB")).toBeInTheDocument()
  })

  it("shows a screenshot fallback when image data is missing", () => {
    const toolContext = context({
      toolName: "browser_screenshot",
      input: { target: "e9" },
      parsedResult: { status: "success" },
      resultBody: JSON.stringify({ status: "success" })
    })

    render(<>{browserScreenshotToolCard.renderExpanded(toolContext)}</>)

    expect(screen.queryByRole("img")).not.toBeInTheDocument()
    expect(screen.getByText("No image preview is available.")).toBeInTheDocument()
  })

  it("does not inline very large screenshot payloads", () => {
    const toolContext = context({
      toolName: "browser_screenshot",
      parsedResult: [
        { type: "image", data: "a".repeat(1_500_001), mimeType: "image/png" }
      ]
    })

    expect(browserScreenshotToolCard.collapsedSummary?.(toolContext)).toBe("Screenshot · Browser screenshot · success")

    render(<>{browserScreenshotToolCard.renderExpanded(toolContext)}</>)

    expect(screen.queryByRole("img")).not.toBeInTheDocument()
    expect(screen.getByText("Image payload is too large to preview inline.")).toBeInTheDocument()
  })

  it("summarizes resize outcomes from the tool input when the result is empty", () => {
    const toolContext = context({
      toolName: "browser_resize",
      input: { width: 390, height: 844 },
      resultBody: ""
    })

    expect(browserResizeToolCard.collapsedSummary?.(toolContext)).toBe("Resize 390x844 · success")

    render(<>{browserResizeToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Resize")).toBeInTheDocument()
    expect(screen.getAllByText("390x844")).toHaveLength(1)
  })

  it("summarizes wait outcomes from text, disappearing text, and time inputs", () => {
    expect(
      browserWaitForToolCard.collapsedSummary?.(
        context({ toolName: "browser_wait_for", input: { text: "Loaded" }, resultBody: "" })
      )
    ).toBe("Wait for \"Loaded\" · success")

    expect(
      browserWaitForToolCard.collapsedSummary?.(
        context({ toolName: "browser_wait_for", input: { text_gone: "Loading" }, resultBody: "" })
      )
    ).toBe("Wait until \"Loading\" disappears · success")

    expect(
      browserWaitForToolCard.collapsedSummary?.(
        context({ toolName: "browser_wait_for", input: { time: 2.5 }, resultBody: "" })
      )
    ).toBe("Wait for 2.5s · success")
  })

  it("renders Browser close outcomes", () => {
    const toolContext = context({
      toolName: "browser_close",
      parsedResult: { closed: true },
      resultBody: JSON.stringify({ closed: true })
    })

    expect(browserCloseToolCard.collapsedSummary?.(toolContext)).toBe("Close browser · success")

    render(<>{browserCloseToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Close browser")).toBeInTheDocument()
    expect(screen.getByText("success")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for unknown or malformed Browser payloads", () => {
    const malformed = context({
      toolName: "browser_snapshot",
      resultBody: "plain unrelated text",
      parsedResult: { oops: true }
    })

    expect(browserSnapshotToolCard.collapsedSummary?.(malformed)).toBeNull()
    expect(browserSnapshotToolCard.renderExpanded(malformed)).toBeNull()
    expect(browserResizeToolCard.renderExpanded(context({ toolName: "browser_resize", input: { width: 390 } }))).toBeNull()
  })
})

import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import browserCloseToolCard from "./browser_close"
import browserClickToolCard from "./browser_click"
import browserDragToolCard from "./browser_drag"
import browserDropToolCard from "./browser_drop"
import browserEvaluateToolCard from "./browser_evaluate"
import browserFileUploadToolCard from "./browser_file_upload"
import browserFillToolCard from "./browser_fill"
import browserHoverToolCard from "./browser_hover"
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
      browserCloseToolCard,
      browserClickToolCard,
      browserFillToolCard,
      browserEvaluateToolCard,
      browserHoverToolCard,
      browserDragToolCard,
      browserDropToolCard,
      browserFileUploadToolCard
    ]

    expect(cards.map((card) => card.toolName)).toEqual([
      "browser_navigate",
      "browser_snapshot",
      "browser_screenshot",
      "browser_resize",
      "browser_wait_for",
      "browser_close",
      "browser_click",
      "browser_fill",
      "browser_evaluate",
      "browser_hover",
      "browser_drag",
      "browser_drop",
      "browser_file_upload"
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

  it("summarizes and renders successful click interactions with page state", () => {
    const toolContext = context({
      toolName: "browser_click",
      input: { element: "Submit button", target: "e3" },
      resultBody: [
        "- Page URL: http://127.0.0.1:3001/submitted",
        "- Page Title: Submitted"
      ].join("\n")
    })

    expect(browserClickToolCard.collapsedSummary?.(toolContext)).toBe(
      "Click Submit button · Submitted (http://127.0.0.1:3001/submitted) · success"
    )

    render(<>{browserClickToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Click")).toBeInTheDocument()
    expect(screen.getByText("Submit button")).toBeInTheDocument()
    expect(screen.getByText("Submitted")).toBeInTheDocument()
    expect(screen.getAllByText("http://127.0.0.1:3001/submitted")).toHaveLength(1)
  })

  it("summarizes fill interactions without exposing the filled text in the collapsed row", () => {
    const toolContext = context({
      toolName: "browser_fill",
      input: { element: "Password field", target: "e4", text: "super-secret" },
      parsedResult: { ok: true }
    })

    expect(browserFillToolCard.collapsedSummary?.(toolContext)).toBe("Fill Password field · success")

    render(<>{browserFillToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Fill")).toBeInTheDocument()
    expect(screen.getByText("Password field")).toBeInTheDocument()
    expect(screen.getByText("12 characters")).toBeInTheDocument()
    expect(screen.queryByText("super-secret")).not.toBeInTheDocument()
  })

  it("summarizes evaluate scalar results without dumping raw JSON", () => {
    const toolContext = context({
      toolName: "browser_evaluate",
      input: { function: "() => document.title" },
      parsedResult: "Dashboard",
      resultBody: "\"Dashboard\""
    })

    expect(browserEvaluateToolCard.collapsedSummary?.(toolContext)).toBe("Evaluate page · \"Dashboard\" · success")

    render(<>{browserEvaluateToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Evaluate")).toBeInTheDocument()
    expect(screen.getAllByText("\"Dashboard\"").length).toBeGreaterThanOrEqual(1)
  })

  it("summarizes evaluate object results and keeps full JSON behind disclosure", () => {
    const toolContext = context({
      toolName: "browser_evaluate",
      input: { element: "Cart badge", target: "e7", function: "(element) => ({ count: Number(element.textContent), visible: true, nested: { ignored: true } })" },
      parsedResult: { result: { count: 3, visible: true, nested: { ignored: true } } },
      resultBody: JSON.stringify({ result: { count: 3, visible: true, nested: { ignored: true } } })
    })

    expect(browserEvaluateToolCard.collapsedSummary?.(toolContext)).toBe("Evaluate Cart badge · { count: 3, visible: true, ... } · success")

    render(<>{browserEvaluateToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Cart badge")).toBeInTheDocument()
    expect(screen.getByText("{ count: 3, visible: true, ... }")).toBeInTheDocument()
    expect(screen.getAllByText(/\"nested\"/).length).toBeGreaterThanOrEqual(1)
  })

  it("renders selector and JavaScript errors readably", () => {
    const selectorError = context({
      toolName: "browser_click",
      input: { element: "Missing button", target: "e404" },
      resultBody: "Error: Ref e404 not found in the current page snapshot",
      resultError: true
    })
    const evaluateError = context({
      toolName: "browser_evaluate",
      input: { function: "() => missing.call()" },
      parsedResult: { error: "ReferenceError: missing is not defined" },
      resultBody: JSON.stringify({ error: "ReferenceError: missing is not defined" }),
      resultError: true
    })

    expect(browserClickToolCard.collapsedSummary?.(selectorError)).toBe("Click Missing button · failed")
    expect(browserEvaluateToolCard.collapsedSummary?.(evaluateError)).toBe("Evaluate page · failed")

    render(
      <>
        {browserClickToolCard.renderExpanded(selectorError)}
        {browserEvaluateToolCard.renderExpanded(evaluateError)}
      </>
    )

    expect(screen.getByText("Ref e404 not found in the current page snapshot")).toBeInTheDocument()
    expect(screen.getByText("ReferenceError: missing is not defined")).toBeInTheDocument()
  })

  it("summarizes other Browser interaction tools exposed by the plugin", () => {
    expect(
      browserHoverToolCard.collapsedSummary?.(
        context({ toolName: "browser_hover", input: { element: "Help icon", target: "e8" }, resultBody: "" })
      )
    ).toBe("Hover Help icon · success")

    expect(
      browserDragToolCard.collapsedSummary?.(
        context({
          toolName: "browser_drag",
          input: { start_element: "Backlog card", start_target: "e1", end_element: "Done column", end_target: "e2" },
          resultBody: ""
        })
      )
    ).toBe("Drag Backlog card -> Done column · success")

    expect(
      browserDropToolCard.collapsedSummary?.(
        context({ toolName: "browser_drop", input: { element: "Drop zone", target: "e9", paths: ["/tmp/a.png"] }, resultBody: "" })
      )
    ).toBe("Drop Drop zone · success")

    expect(
      browserFileUploadToolCard.collapsedSummary?.(
        context({ toolName: "browser_file_upload", input: { paths: ["/tmp/a.png", "/tmp/b.png"] }, resultBody: "" })
      )
    ).toBe("File upload 2 files · success")
  })

  it("falls back to the generic renderer for unknown or malformed Browser payloads", () => {
    const malformed = context({
      toolName: "browser_snapshot",
      resultBody: "plain unrelated text",
      parsedResult: { oops: true }
    })
    const malformedInteraction = context({
      toolName: "browser_click",
      parsedResult: { oops: true }
    })

    expect(browserSnapshotToolCard.collapsedSummary?.(malformed)).toBeNull()
    expect(browserSnapshotToolCard.renderExpanded(malformed)).toBeNull()
    expect(browserClickToolCard.collapsedSummary?.(malformedInteraction)).toBeNull()
    expect(browserClickToolCard.renderExpanded(malformedInteraction)).toBeNull()
    expect(browserResizeToolCard.renderExpanded(context({ toolName: "browser_resize", input: { width: 390 } }))).toBeNull()
  })
})

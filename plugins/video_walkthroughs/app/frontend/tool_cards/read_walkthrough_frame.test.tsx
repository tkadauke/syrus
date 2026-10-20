import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolName } from "@app/routes/chat/toolRendering"
import { setSlugReferenceRegistryForTests } from "@app/lib/slugReferenceRegistry"
import readWalkthroughFrameToolCard, { examples } from "./read_walkthrough_frame"

const IMAGE_BLOCK = { type: "image", data: "ZmFrZS1qcGVn", mimeType: "image/jpeg" }
const INSTRUCTION_BLOCK = {
  type: "text",
  text: "Screenshot from walkthrough #42 at 1:12. Read any on-screen text directly off this image and use the exact characters you see — don't guess."
}

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_walkthrough_frame",
    input: { walkthrough_id: 42, timestamp: "01:11" },
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

beforeEach(() => {
  setSlugReferenceRegistryForTests([
    {
      prefix: "JOB",
      type: "job",
      displayLabel: "Job",
      copyable: true,
      linkable: true,
      previewAvailable: false,
      linkifiesGeneratedText: true,
      hrefTemplate: "/jobs/:id",
      mobileInteractionHints: {},
      pluginPreviewComponent: null
    }
  ])
})

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("read_walkthrough_frame tool card", () => {
  it.each([
    ["Claude", "mcp__video_walkthroughs__read_walkthrough_frame", [IMAGE_BLOCK, INSTRUCTION_BLOCK]],
    ["Codex", "syrus-chat-sidecar.read_walkthrough_frame", { content: [IMAGE_BLOCK, INSTRUCTION_BLOCK] }],
    ["Muse", "read_walkthrough_frame", { result: { content: [IMAGE_BLOCK, INSTRUCTION_BLOCK] } }]
  ])("renders the real image content through the %s envelope without exposing agent instructions", (_provider, rawToolName, parsedResult) => {
    const cardContext = context({ toolName: normalizedToolName(rawToolName), parsedResult })

    expect(cardContext.toolName).toBe("read_walkthrough_frame")
    expect(readWalkthroughFrameToolCard.collapsedSummary?.(cardContext)).toBe("Walkthrough 42 - 1:12 - captured")
    render(<>{readWalkthroughFrameToolCard.renderExpanded(cardContext)}</>)

    expect(screen.getByText("captured")).toBeInTheDocument()
    expect(screen.getByText("WALKTHROUGH-42")).toBeInTheDocument()
    expect(screen.getAllByText("1:12").length).toBeGreaterThan(0)
    expect(screen.getByRole("img", { name: "Walkthrough frame" })).toHaveAttribute("src", "data:image/jpeg;base64,ZmFrZS1qcGVn")
    expect(screen.queryByText(/Read any on-screen text/)).not.toBeInTheDocument()
    expect(screen.queryByText("Context")).not.toBeInTheDocument()
  })

  it("renders structured transcript and context as bounded markdown with a full modal", () => {
    const parsedResult = {
      walkthrough: { title: "Checkout regression" },
      timestamp: "01:12",
      range: { start: "01:10", end: "01:15" },
      frame_index: 2160,
      image: { src: "data:image/jpeg;base64,ZmFrZQ==", mimeType: "image/jpeg", label: "Checkout regression at 01:12" },
      transcript: "The **Save** button is clicked.\n\n" + "Additional transcript detail. ".repeat(60),
      context: "See JOB-123 and https://example.com/checkout for the surrounding flow.",
      links: [{ label: "Source video", url: "/api/v1/app/video_walkthroughs/42" }]
    }

    render(<MemoryRouter>{readWalkthroughFrameToolCard.renderExpanded(context({ parsedResult }))}</MemoryRouter>)

    expect(screen.getByText("Save").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "JOB-123" })).toHaveAttribute("href", "/jobs/123")
    expect(screen.getByRole("link", { name: "https://example.com/checkout" })).toHaveAttribute("href", "https://example.com/checkout")
    expect(screen.getByRole("link", { name: "Source video" })).toHaveAttribute("href", "/api/v1/app/video_walkthroughs/42")
    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Transcript" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Copy .*Transcript/i })).toBeInTheDocument()
  })

  it("renders pending and empty results explicitly", () => {
    const pending = context({ parsedResult: null, resultBody: "" })
    expect(readWalkthroughFrameToolCard.collapsedSummary?.(pending)).toBe("Walkthrough 42 - 01:11 - pending")
    const { rerender } = render(<>{readWalkthroughFrameToolCard.renderExpanded(pending)}</>)
    expect(screen.getByText("Waiting for a frame image.")).toBeInTheDocument()

    const empty = context({ parsedResult: {}, resultBody: "{}" })
    rerender(<>{readWalkthroughFrameToolCard.renderExpanded(empty)}</>)
    expect(screen.getByText("missing")).toBeInTheDocument()
    expect(screen.getByText("No frame image or thumbnail was returned.")).toBeInTheDocument()
  })

  it("renders an MCP text-block failure as a styled error without losing request metadata", () => {
    const parsedResult = [{ type: "text", text: "timestamp must be mm:ss or whole seconds" }]
    const errorContext = context({ input: { walkthrough_id: 42, timestamp: "banana" }, parsedResult, resultError: true })

    expect(readWalkthroughFrameToolCard.collapsedSummary?.(errorContext)).toBe("Walkthrough 42 - banana - failed")
    render(<>{readWalkthroughFrameToolCard.renderExpanded(errorContext)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("timestamp must be mm:ss or whole seconds")).toHaveClass("text-danger-text")
    expect(screen.getByText("banana")).toBeInTheDocument()
    expect(screen.getByText("WALKTHROUGH-42")).toBeInTheDocument()
  })

  it("exports catalog examples using the real content envelope", () => {
    expect(examples.map((example) => example.id)).toEqual(["normal_frame", "missing_frame", "capture_error"])
    expect(examples[0].parsedResult).toEqual(expect.arrayContaining([expect.objectContaining({ type: "image" }), expect.objectContaining({ type: "text" })]))
  })
})

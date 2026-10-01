import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import readWalkthroughFrameToolCard, { examples } from "./read_walkthrough_frame"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_walkthrough_frame",
    input: { walkthrough_id: 42, timestamp: "01:12" },
    resultBody: "{}",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

describe("read_walkthrough_frame tool card", () => {
  it("summarizes and renders a captured frame with metadata, transcript, context, and artifact links", () => {
    const parsedResult = {
      walkthrough: { id: 42, title: "Checkout regression" },
      timestamp: "01:12",
      range: { start: "01:10", end: "01:15" },
      frame_index: 2160,
      image: { data: "/9j/4AAQSkZJRgABAQAAAQABAAD/2w==", mimeType: "image/jpeg", label: "Checkout regression at 01:12" },
      transcript: "The save button is clicked.",
      context: "The error toast is visible beside the form.",
      links: [{ label: "Source video", url: "/api/v1/app/video_walkthroughs/42" }]
    }

    expect(readWalkthroughFrameToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Checkout regression - frame 2160 @ 01:12 - captured")

    render(<>{readWalkthroughFrameToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Walkthrough frame")).toBeInTheDocument()
    expect(screen.getByText("captured")).toBeInTheDocument()
    expect(screen.getByText("Checkout regression")).toBeInTheDocument()
    expect(screen.getByText("2160")).toBeInTheDocument()
    expect(screen.getAllByText("01:12").length).toBeGreaterThan(0)
    expect(screen.getByText("The save button is clicked.")).toBeInTheDocument()
    expect(screen.getByText("The error toast is visible beside the form.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Source video" })).toHaveAttribute("href", "/api/v1/app/video_walkthroughs/42")
    expect(screen.getByRole("img", { name: "Checkout regression at 01:12" })).toHaveAttribute("src", expect.stringContaining("data:image/jpeg;base64,"))
  })

  it("renders a missing-frame payload without an inline image", () => {
    const parsedResult = {
      walkthrough_id: 42,
      timestamp: "05:00",
      status: "missing",
      message: "Frame extraction produced no image at this timestamp.",
      transcript: "The recording had already ended."
    }

    expect(readWalkthroughFrameToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Walkthrough 42 - 05:00 - missing frame")

    render(<>{readWalkthroughFrameToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("missing")).toBeInTheDocument()
    expect(screen.getByText("Frame extraction produced no image at this timestamp.")).toBeInTheDocument()
    expect(screen.getByText("No frame image or thumbnail was returned.")).toBeInTheDocument()
    expect(screen.getByText("The recording had already ended.")).toBeInTheDocument()
  })

  it("renders an error payload while preserving the requested walkthrough and timestamp", () => {
    const parsedResult = {
      walkthrough_id: 42,
      timestamp: "banana",
      error: "timestamp must be mm:ss or whole seconds"
    }

    expect(readWalkthroughFrameToolCard.collapsedSummary?.(context({ parsedResult, resultError: true }))).toBe("Walkthrough 42 - banana - failed")

    render(<>{readWalkthroughFrameToolCard.renderExpanded(context({ parsedResult, resultError: true }))}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("timestamp must be mm:ss or whole seconds")).toBeInTheDocument()
    expect(screen.getByText("banana")).toBeInTheDocument()
  })

  it("exports catalog examples for normal, missing-frame, and error payloads", () => {
    expect(examples.map((example) => example.id)).toEqual(["normal_frame", "missing_frame", "capture_error"])
  })
})

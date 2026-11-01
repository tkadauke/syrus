import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import showPipelineCard from "./show_pipeline"

function context(parsedResult: unknown): ToolCardContext {
  return { toolName: "show_pipeline", input: {}, resultBody: "{}", resultError: false, parsedResult, chatSessionId: 8 }
}

describe("show_pipeline tool card", () => {
  it("replays only after an explicit open action and copies the canonical link", () => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
    const listener = vi.fn()
    window.addEventListener("syrus:tool-presentation", listener)
    const card = context({ path: "/repositories/7/plugin/sdlc-pipeline?q=kept", repository: { slug: "acme/widgets" }, at: null })

    render(<>{showPipelineCard.renderExpanded(card)}</>)
    expect(listener).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: "Open pipeline" }))
    expect(listener).toHaveBeenCalledTimes(1)
    fireEvent.click(screen.getByRole("button", { name: "Copy link" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("http://localhost:3000/repositories/7/plugin/sdlc-pipeline?q=kept")
    window.removeEventListener("syrus:tool-presentation", listener)
  })

  it("renders a safe fallback for malformed stored results", () => {
    render(<>{showPipelineCard.renderExpanded(context({ path: 42 }))}</>)
    expect(screen.getByText("This pipeline result cannot be displayed.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Open pipeline" })).not.toBeInTheDocument()
  })
})

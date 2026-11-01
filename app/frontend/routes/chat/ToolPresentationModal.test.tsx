import { act, fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ToolPresentationModal } from "./ToolPresentationModal"

describe("ToolPresentationModal", () => {
  beforeEach(() => {
    Object.assign(navigator, { clipboard: { writeText: vi.fn().mockResolvedValue(undefined) } })
  })

  it("opens only for a live matching-chat event and does not rehydrate itself", () => {
    const view = render(<ToolPresentationModal chatId="8" prefix="/app" />)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    act(() => window.dispatchEvent(new CustomEvent("syrus:tool-presentation", { detail: { chat_session_id: 9, title: "Other", path: "/elsewhere" } })))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    act(() =>
      window.dispatchEvent(
        new CustomEvent("syrus:tool-presentation", { detail: { chat_session_id: 8, title: "Pipeline", path: "/repositories/2/plugin/sdlc-pipeline?q=x" } })
      )
    )
    expect(screen.getByRole("dialog", { name: "Pipeline" })).toBeInTheDocument()
    expect(screen.getByTitle("Pipeline")).toHaveAttribute("src", "/app/repositories/2/plugin/sdlc-pipeline?q=x")
    expect(screen.getByRole("dialog")).toHaveClass("h-[100dvh]", "sm:h-[94dvh]")
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
    fireEvent(window, new Event("resize"))
    expect(screen.getByTitle("Pipeline")).toHaveAttribute("src", "/app/repositories/2/plugin/sdlc-pipeline?q=x")
    expect(screen.getByRole("link", { name: "Open full page" })).toHaveAttribute("href", "/app/repositories/2/plugin/sdlc-pipeline?q=x")
    fireEvent.click(screen.getByRole("button", { name: "Copy link" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("http://localhost:3000/app/repositories/2/plugin/sdlc-pipeline?q=x")
    fireEvent.keyDown(document, { key: "Escape" })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()

    view.unmount()
    render(<ToolPresentationModal chatId="8" prefix="/app" />)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})

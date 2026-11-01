import { act, fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ToolPresentationModal } from "./ToolPresentationModal"

describe("ToolPresentationModal", () => {
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
    fireEvent.click(screen.getByRole("button", { name: "Close" }))

    view.unmount()
    render(<ToolPresentationModal chatId="8" prefix="/app" />)
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})

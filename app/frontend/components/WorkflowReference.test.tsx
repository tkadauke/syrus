import { act, fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { WorkflowReference } from "./WorkflowReference"

vi.mock("./WorkflowPreviewCard", () => ({
  WorkflowPreviewCard: ({ id }: { id: number }) => <div data-testid="workflow-preview">WF-{id} preview</div>
}))

function mockPointer(fine: boolean) {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query.includes("(hover: hover) and (pointer: fine)") ? fine : query.includes("(hover: none) and (pointer: coarse)") ? !fine : false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn()
    }))
  })
}

function renderReference() {
  render(
    <MemoryRouter>
      <WorkflowReference path="/app-shell/jobs/7?tab=workflows#workflow-42" slug="WF-42" />
    </MemoryRouter>
  )
}

describe("WorkflowReference", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("opens the workflow preview on desktop hover and focus", async () => {
    vi.useFakeTimers()
    mockPointer(true)
    renderReference()
    const link = screen.getByRole("link", { name: "WF-42" })

    fireEvent.mouseEnter(link)
    await act(async () => vi.advanceTimersByTime(300))
    expect(screen.getByTestId("workflow-preview")).toHaveTextContent("WF-42 preview")

    fireEvent.mouseLeave(link)
    await act(async () => vi.advanceTimersByTime(100))
    fireEvent.focus(link)
    expect(screen.getByTestId("workflow-preview")).toBeInTheDocument()
  })

  it("opens touch actions with the caller-provided destination", () => {
    mockPointer(false)
    renderReference()

    fireEvent.click(screen.getByRole("link", { name: "WF-42" }))

    expect(screen.getByRole("dialog", { name: "Actions for WF-42" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open WF-42" })).toHaveAttribute("href", "/app-shell/jobs/7?tab=workflows#workflow-42")
    expect(screen.getByRole("button", { name: "Copy WF-42" })).toBeInTheDocument()
    expect(screen.getByTestId("workflow-preview")).toBeInTheDocument()
  })
})

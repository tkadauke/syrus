import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { WorkflowPreviewCard } from "./WorkflowPreviewCard"

function renderCard() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(<QueryClientProvider client={client}><MemoryRouter><Routes><Route path="*" element={<><WorkflowPreviewCard id={42} /><div data-testid="location" /></>} /></Routes></MemoryRouter></QueryClientProvider>)
}

describe("WorkflowPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders its header and ordered projected steps and opens from the card", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ workflow: {
      id: 42, slug: "WF-42", path: "/jobs/7?tab=workflows#workflow-42",
      trigger_kind: "initial", trigger_label: "Initial implementation", state: "running",
      steps: [
        { id: 1, display_name: "Prepare", status: "succeeded" },
        { ellipsis: true },
        { id: 3, display_name: "RSpec", status: "warning" }
      ]
    } }))
    renderCard()

    await screen.findByText("Initial implementation")
    expect(screen.getByRole("link", { name: "WF-42" })).toHaveAttribute("href", "/jobs/7?tab=workflows#workflow-42")
    expect(screen.getByText("RSpec")).toBeInTheDocument()
    expect(screen.getByText("warning")).toBeInTheDocument()
    fireEvent.keyDown(screen.getByRole("link", { name: /WF-42 Initial implementation/ }), { key: "Enter" })
  })

  it("does not navigate when the copy action is clicked", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ workflow: {
      id: 42, slug: "WF-42", path: "/jobs/7?tab=workflows#workflow-42",
      trigger_kind: "initial", trigger_label: "Initial implementation", state: "running", steps: []
    } }))
    renderCard()
    await screen.findByText("Initial implementation")
    fireEvent.click(screen.getByRole("button", { name: "Copy WF-42 to clipboard" }))
    expect(screen.getByRole("link", { name: "WF-42" })).toBeInTheDocument()
  })
})

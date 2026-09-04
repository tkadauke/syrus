import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, useLocation } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import OpenWorkspaceButton from "./OpenWorkspaceButton"

function LocationProbe() {
  const location = useLocation()
  return <div data-testid="location">{location.pathname}{location.search}</div>
}

describe("OpenWorkspaceButton", () => {
  // This used to be a hardcoded button in core's WorkflowGraph, gated on a
  // feature flag; it reaches the job page through the job.workflow.actions
  // slot now.
  it("opens a terminal session for the workflow and navigates to it", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      session: { id: 77, name: "WF-4 workspace", working_directory: "/tmp/workflows/4", started_at: "2026-06-27T10:00:00Z", finished_at: null, outcome: null, workflow_id: 4 }
    }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={[ "/app-shell/jobs/1" ]}>
          <OpenWorkspaceButton prefix="/app-shell" workflow={{ id: 4, slug: "WF-4" }} />
          <LocationProbe />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "Open terminal in workspace" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/terminal_sessions",
      expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ terminal_session: { workflow_id: 4, name: "WF-4 workspace" } })
      })
    ))
    await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("/app-shell/terminal?session=77"))

    fetchSpy.mockRestore()
  })

  it("renders nothing without a workflow" , () => {
    const { container } = render(
      <MemoryRouter><OpenWorkspaceButton /></MemoryRouter>
    )

    expect(container).toBeEmptyDOMElement()
  })
})

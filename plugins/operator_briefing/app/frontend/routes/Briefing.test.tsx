import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import BriefingRoute from "./Briefing"
import type { BriefingPayload } from "../api/briefing"

function briefingPayload(overrides: Partial<BriefingPayload> = {}): BriefingPayload {
  return {
    settings: {
      cadence_expression: "daily",
      budget_check_enabled: false,
      agent_provider: null,
      last_scheduled_at: null,
      budget_gate: {
        skip: false,
        reason: null
      }
    },
    source_preferences: [],
    source_preference_suggestions: [],
    repositories: [],
    subscriptions: [
      {
        id: 1,
        enabled: true,
        repository: {
          id: 1,
          slug: "acme/widgets",
          path: "/repositories/1"
        }
      }
    ],
    generated_at: "2026-09-27T00:00:00Z",
    ...overrides
  }
}

function renderBriefing(payload: BriefingPayload, path = "/app-shell/briefing") {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <BriefingRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("BriefingRoute", () => {
  it("surfaces unenforced budget checks when the backend reports a gate reason", async () => {
    renderBriefing(
      briefingPayload({
        settings: {
          cadence_expression: "daily",
          budget_check_enabled: true,
          agent_provider: null,
          last_scheduled_at: null,
          budget_gate: {
            skip: false,
            reason: "no_budget_allowance_available"
          }
        }
      })
    )

    fireEvent.click(await screen.findByRole("button", { name: "Settings" }))

    expect(await screen.findByText(/Budget checks are enabled, but spend protection is not currently enforced/)).toBeInTheDocument()
    expect(screen.getByText(/no_budget_allowance_available/)).toBeInTheDocument()
  })

  it("keeps the budget caveat hidden when budget checks are disabled", async () => {
    renderBriefing(briefingPayload())

    fireEvent.click(await screen.findByRole("button", { name: "Settings" }))

    await waitFor(() => expect(screen.getByRole("dialog", { name: "Settings" })).toBeInTheDocument())
    expect(screen.queryByText(/Budget checks are enabled/)).not.toBeInTheDocument()
  })

  it("loads archived briefing content from the history endpoint on demand", async () => {
    const archived = {
      id: 44,
      slug: "BRIEFING-44",
      window_start: "2026-09-20T00:00:00Z",
      window_end: "2026-09-21T00:00:00Z",
      job: { id: 9, slug: "JOB-9", title: "Archived briefing", state: "closed", path: "/jobs/9" }
    }
    const fetchMock = vi
      .spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse(
          briefingPayload({
            repositories: [
              {
                repository: { id: 1, slug: "acme/widgets", path: "/repositories/1" },
                current: null,
                history: [archived],
                status: { kind: "no_activity", message: null }
              }
            ]
          })
        )
      )
      .mockResolvedValueOnce(
        jsonResponse({
          briefing: {
            ...archived,
            live: false,
            latest_revision: {
              id: 3,
              revision_number: 1,
              generated_at: "2026-09-21T00:00:00Z",
              content_blocks: [{ kind: "narrative", payload: { text: "Archived detail" } }]
            }
          }
        })
      )

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/briefing/history?briefing_id=44"]}>
          <BriefingRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Archived detail")).toBeInTheDocument()
    expect(fetchMock).toHaveBeenNthCalledWith(2, "/api/v1/app/briefing/history?briefing_id=44", expect.anything())
  })
})

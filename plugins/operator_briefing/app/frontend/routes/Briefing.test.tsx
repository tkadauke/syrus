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

function renderBriefing(payload: BriefingPayload) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/briefing"]}>
        <BriefingRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("BriefingRoute", () => {
  it("surfaces unenforced budget checks when the backend reports a gate reason", async () => {
    renderBriefing(briefingPayload({
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
    }))

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
})

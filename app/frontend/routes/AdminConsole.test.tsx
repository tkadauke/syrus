import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"

import { AdminConsole } from "./AdminConsole"

function consolePayload(overrides: Record<string, unknown> = {}) {
  return {
    settings: {
      polling_paused: false,
      runs_paused: false,
      signups_open: true,
      max_job_failures: 5,
      grade_max_iterations: 3,
      merge_train_enabled: false
    },
    users: [],
    recent_admin_actions: [],
    active_runs: 0,
    ...overrides
  }
}

describe("AdminConsole maintenance section", () => {
  afterEach(() => vi.restoreAllMocks())

  it("restarts web without warning when there are no active runs", async () => {
    let restartBody: unknown
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/api/v1/app/admin/restart") && init?.method === "POST") {
        restartBody = JSON.parse(String(init.body))
        return Promise.resolve(jsonResponse({ initiated: true, component: "web", active_runs: 0 }, 202))
      }
      return Promise.resolve(jsonResponse(consolePayload()))
    })

    renderRoute(<AdminConsole />)

    fireEvent.click(await screen.findByRole("button", { name: "Restart web" }))
    fireEvent.click(await screen.findByRole("button", { name: "Restart" }))

    await waitFor(() => expect(restartBody).toEqual({ component: "web", force: false }))
    expect(await screen.findByText(/Restart initiated/)).toBeInTheDocument()
  })

  it("warns about active runs and forces the worker restart on confirm", async () => {
    let restartBody: unknown
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input).endsWith("/api/v1/app/admin/restart") && init?.method === "POST") {
        restartBody = JSON.parse(String(init.body))
        return Promise.resolve(jsonResponse({ initiated: true, component: "worker", active_runs: 3 }, 202))
      }
      return Promise.resolve(jsonResponse(consolePayload({ active_runs: 3 })))
    })

    renderRoute(<AdminConsole />)

    fireEvent.click(await screen.findByRole("button", { name: "Restart worker" }))
    expect(await screen.findByText(/3 active run/)).toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: "Force restart" }))

    await waitFor(() => expect(restartBody).toEqual({ component: "worker", force: true }))
  })

  it("shows toggle failures and refreshes console state", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((_input, init) =>
      Promise.resolve(init?.method === "POST"
        ? jsonResponse({ error: { message: "Polling setting could not be saved" } }, 422)
        : jsonResponse(consolePayload()))
    )

    renderRoute(<AdminConsole />)
    fireEvent.click(await screen.findByRole("button", { name: "Pause polling" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("Polling setting could not be saved")
    await waitFor(() => expect(fetchSpy.mock.calls.filter(([, init]) => init?.method !== "POST").length).toBeGreaterThan(1))
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={["/app-shell/admin/console"]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

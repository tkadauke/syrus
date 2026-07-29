import { act, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { STATUS } from "react-joyride"
import { useTour } from "./useTour"
import type { BootstrapPayload } from "../api/bootstrap"
import { jsonResponse } from "../testSupport"

function buildBootstrap(seenTours: string[] = []): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "test@example.com",
      name: "Test User",
      first_name: null,
      last_name: null,
      display_name: "Test User",
      admin: false,
      role: "developer",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: null,
      agent_max_turns: 200,
      gemini_configured: false,
      theme: "light",
      locale: "en",
      seen_tours: seenTours
    },
    team_user_count: 1,
    app: {
      revision: "abc123",
      revision_url: null,
      version: null,
      built_at: null,
      bug_report_mode: null,
      report_issue_repo_slug: "owner/repo"
    },
    setup_status: null,
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/session/new",
      sign_in_path: "/session/new",
      docs_url: "https://docs.example.com",
      evaluation_url: "https://example.com"
    },
    unread_notifications_count: 0,
    csrf_token: "test-token",
    feature_flags: {}
  }
}

function Probe({ tourId }: { tourId: string }) {
  const { run, handleJoyrideCallback } = useTour(tourId)
  return (
    <div>
      <span data-testid="run">{String(run)}</span>
      <button
        data-testid="finish"
        onClick={() => handleJoyrideCallback({ status: STATUS.FINISHED })}
        type="button"
      >
        finish
      </button>
      <button
        data-testid="skip"
        onClick={() => handleJoyrideCallback({ status: STATUS.SKIPPED })}
        type="button"
      >
        skip
      </button>
      <button
        data-testid="running"
        onClick={() => handleJoyrideCallback({ status: STATUS.RUNNING })}
        type="button"
      >
        running
      </button>
    </div>
  )
}

function renderProbe(tourId: string, seenTours: string[] = []) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData(["bootstrap"], buildBootstrap(seenTours))
  return {
    queryClient,
    ...render(
      <QueryClientProvider client={queryClient}>
        <Probe tourId={tourId} />
      </QueryClientProvider>
    )
  }
}

describe("useTour", () => {
  it("run is true when tourId is not in seen_tours", () => {
    renderProbe("dashboard", [])

    expect(screen.getByTestId("run")).toHaveTextContent("true")
  })

  it("run is false when tourId is already in seen_tours", () => {
    renderProbe("dashboard", ["dashboard", "job_detail"])

    expect(screen.getByTestId("run")).toHaveTextContent("false")
  })

  it("run is true when a different tourId is seen but not this one", () => {
    renderProbe("dashboard", ["job_detail"])

    expect(screen.getByTestId("run")).toHaveTextContent("true")
  })

  it("calls the dismiss API on FINISHED", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse({}))

    renderProbe("dashboard", [])

    act(() => screen.getByTestId("finish").click())

    await waitFor(() => {
      const dismissCall = fetchSpy.mock.calls.find(([url]) => String(url).includes("/api/v1/app/tours/dismiss"))
      expect(dismissCall).toBeDefined()
    })

    const dismissCall = fetchSpy.mock.calls.find(([url]) => String(url).includes("/api/v1/app/tours/dismiss"))
    expect(dismissCall).toBeDefined()
    const [, options] = dismissCall!
    expect(JSON.parse(options?.body as string)).toEqual({ tour_id: "dashboard" })
  })

  it("calls the dismiss API on SKIPPED", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse({}))

    renderProbe("dashboard", [])

    act(() => screen.getByTestId("skip").click())

    await waitFor(() => {
      const dismissCall = fetchSpy.mock.calls.find(([url]) => String(url).includes("/api/v1/app/tours/dismiss"))
      expect(dismissCall).toBeDefined()
    })
  })

  it("does not call the dismiss API for other statuses", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse({}))

    renderProbe("dashboard", [])

    act(() => screen.getByTestId("running").click())

    // Wait a tick to allow any potential fetch to fire
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0))
    })

    const dismissCall = fetchSpy.mock.calls.find(([url]) => String(url).includes("/api/v1/app/tours/dismiss"))
    expect(dismissCall).toBeUndefined()
  })

  it("triggers a bootstrap refetch after dismissing so seen_tours stays in sync", async () => {
    let bootstrapCallCount = 0
    vi.spyOn(globalThis, "fetch").mockImplementation((url) => {
      if (String(url).includes("/api/v1/app/bootstrap")) {
        bootstrapCallCount++
        // Second and later fetches return the tour as seen
        const seenTours = bootstrapCallCount > 1 ? ["dashboard"] : []
        return Promise.resolve(jsonResponse(buildBootstrap(seenTours)))
      }
      return Promise.resolve(jsonResponse({}))
    })

    renderProbe("dashboard", [])

    // Wait for the initial bootstrap fetch (stale data triggers refetch on mount)
    await waitFor(() => expect(bootstrapCallCount).toBeGreaterThanOrEqual(1))
    const countBeforeDismiss = bootstrapCallCount

    act(() => screen.getByTestId("finish").click())

    // onSuccess from dismiss mutation calls invalidateQueries → triggers another fetch
    await waitFor(() => {
      expect(bootstrapCallCount).toBeGreaterThan(countBeforeDismiss)
    })
  })
})

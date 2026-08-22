import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { AdminBuildCache } from "./AdminBuildCache"
import * as useConfirmModule from "../hooks/useConfirm"

function buildCachePayload(overrides: Record<string, unknown> = {}) {
  return {
    configured: true,
    stats: {
      object_count: 42,
      total_size_bytes: 123456,
      oldest_object: { key: "a", size: 10, last_modified: "2026-01-01T00:00:00Z" },
      newest_object: { key: "b", size: 20, last_modified: "2026-02-01T00:00:00Z" },
      truncated: false
    },
    stats_error: null,
    pending_request: null,
    recent_requests: [],
    ...overrides
  }
}

function pendingRequestPayload(overrides: Record<string, unknown> = {}) {
  return {
    id: 7,
    scope: "full",
    older_than_days: null,
    reason: "clearing out stale artifacts",
    state: "pending",
    result: null,
    requested_by: "admin@example.com",
    created_at: "2026-08-01T00:00:00Z",
    confirmed_at: null,
    cancelled_at: null,
    ...overrides
  }
}

function renderPage(fetchImpl: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>) {
  vi.spyOn(window, "fetch").mockImplementation(fetchImpl as any)
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <AdminBuildCache />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminBuildCache", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows a not-configured message when SCCACHE_BUCKET is unset", async () => {
    renderPage(() => Promise.resolve(jsonResponse(buildCachePayload({ configured: false, stats: null }))))

    expect(await screen.findByText(/not configured/i)).toBeInTheDocument()
    expect(screen.queryByTestId("build-cache-stats")).not.toBeInTheDocument()
  })

  it("shows bucket stats when configured", async () => {
    renderPage(() => Promise.resolve(jsonResponse(buildCachePayload())))

    expect(await screen.findByTestId("build-cache-stats")).toBeInTheDocument()
    expect(screen.getByText("42")).toBeInTheDocument()
  })

  describe("requesting a clear", () => {
    it("does not clear the bucket just from filling out the form", async () => {
      const fetchSpy = vi.fn().mockResolvedValue(jsonResponse(buildCachePayload()))
      renderPage(fetchSpy)

      await screen.findByTestId("build-cache-clear-form")
      fireEvent.change(screen.getByLabelText(/Reason/i), { target: { value: "cleanup" } })

      expect(fetchSpy).not.toHaveBeenCalledWith(
        expect.stringContaining("/clear_requests"),
        expect.anything()
      )
    })

    it("disables the request button until a reason is entered", async () => {
      renderPage(() => Promise.resolve(jsonResponse(buildCachePayload())))

      await screen.findByTestId("build-cache-clear-form")
      expect(screen.getByRole("button", { name: /Request clear/i })).toBeDisabled()

      fireEvent.change(screen.getByLabelText(/Reason/i), { target: { value: "cleanup" } })

      expect(screen.getByRole("button", { name: /Request clear/i })).toBeEnabled()
    })

    it("creates a pending request (without executing a clear) when submitted", async () => {
      const fetchSpy = vi.fn().mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        if (url === "/api/v1/app/admin/build_cache/clear_requests" && init?.method === "POST") {
          return Promise.resolve(jsonResponse(buildCachePayload({ pending_request: pendingRequestPayload() })))
        }
        return Promise.resolve(jsonResponse(buildCachePayload()))
      })
      renderPage(fetchSpy)

      await screen.findByTestId("build-cache-clear-form")
      fireEvent.change(screen.getByLabelText(/Reason/i), { target: { value: "clearing out stale artifacts" } })
      fireEvent.click(screen.getByRole("button", { name: /Request clear/i }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/admin/build_cache/clear_requests",
          expect.objectContaining({ method: "POST" })
        )
      })
      expect(await screen.findByTestId("build-cache-pending-request")).toBeInTheDocument()
      // Creating the request must never itself hit a confirm/execute endpoint.
      expect(fetchSpy).not.toHaveBeenCalledWith(expect.stringContaining("/confirm"), expect.anything())
    })
  })

  describe("confirming a pending request", () => {
    let mockConfirm: ReturnType<typeof vi.fn>

    beforeEach(() => {
      mockConfirm = vi.fn().mockResolvedValue(true)
      vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
    })

    it("asks for confirmation before clearing", async () => {
      renderPage(() => Promise.resolve(jsonResponse(buildCachePayload({ pending_request: pendingRequestPayload() }))))

      const confirmButton = await screen.findByRole("button", { name: /Confirm and clear/i })
      fireEvent.click(confirmButton)

      await waitFor(() => {
        expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
      })
    })

    it("only calls the confirm endpoint once the user confirms", async () => {
      const fetchSpy = vi.fn().mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        if (url === "/api/v1/app/admin/build_cache/clear_requests/7/confirm" && init?.method === "POST") {
          return Promise.resolve(jsonResponse(buildCachePayload({
            recent_requests: [ pendingRequestPayload({ state: "confirmed", result: { deleted_count: 3, bytes_freed: 300, truncated: false } }) ]
          })))
        }
        return Promise.resolve(jsonResponse(buildCachePayload({ pending_request: pendingRequestPayload() })))
      })
      renderPage(fetchSpy)

      const confirmButton = await screen.findByRole("button", { name: /Confirm and clear/i })
      fireEvent.click(confirmButton)

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/admin/build_cache/clear_requests/7/confirm",
          expect.objectContaining({ method: "POST" })
        )
      })
      expect(await screen.findByText(/Cleared/i)).toBeInTheDocument()
    })

    it("does not call the confirm endpoint when the user cancels the confirmation dialog", async () => {
      mockConfirm.mockResolvedValue(false)
      const fetchSpy = vi.fn().mockResolvedValue(jsonResponse(buildCachePayload({ pending_request: pendingRequestPayload() })))
      renderPage(fetchSpy)

      const confirmButton = await screen.findByRole("button", { name: /Confirm and clear/i })
      fireEvent.click(confirmButton)

      await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
      expect(fetchSpy).not.toHaveBeenCalledWith(expect.stringContaining("/confirm"), expect.anything())
    })
  })
})

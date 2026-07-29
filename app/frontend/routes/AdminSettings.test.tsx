import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { AdminSettings } from "./AdminSettings"
import * as useConfirmModule from "../hooks/useConfirm"

function adminPayload(overrides: Record<string, unknown> = {}) {
  return {
    settings: {
      signups_open: false,
      max_concurrent_agent_runs: 0,
      video_retention_days: 7,
      video_storage_budget_bytes: 2147483648,
      grade_max_iterations: 3,
      adversarial_review_rounds: 0,
      merge_train_enabled: false,
      merge_train_max_size: 10,
      clearable_secrets: [
        { key: "gemini_api_key", label: "Gemini API key", set: true }
      ]
    },
    ...overrides
  }
}

function renderRoute() {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminPayload()))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <AdminSettings />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminSettings SecretRow", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when clearing a secret", async () => {
    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    fireEvent.click(clearButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/settings/clear_secret" && init?.method === "POST") return Promise.resolve(jsonResponse(adminPayload({ message: "Cleared." })))
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    fireEvent.click(clearButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.objectContaining({ method: "POST" }))
    })
  })

  it("does not call the API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminPayload()))

    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    await act(async () => { fireEvent.click(clearButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.anything())
  })
})

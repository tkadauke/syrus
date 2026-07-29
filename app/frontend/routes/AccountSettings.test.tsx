import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { CredentialsRoute } from "./AccountSettings"
import * as useConfirmModule from "../hooks/useConfirm"

function credentialsPayload(overrides: Record<string, unknown> = {}) {
  return {
    user: {
      id: 1,
      email_address: "ada@example.com",
      name: "Ada Lovelace",
      first_name: "Ada",
      last_name: "Lovelace",
      profile_location: null,
      profile_company: null,
      profile_website: null,
      display_name: "Ada Lovelace",
      github_handle: null,
      profile_bio: null,
      avatar_url: null,
      admin: true,
      role: "operator",
      agent_provider: "claude",
      chat_provider: null,
      codex_auth_mode: "api_key",
      agent_max_turns: 200,
      scheduling_paused: false,
      auto_approve_mode: "never",
      locale: "en",
      notification_preferences: { desktop_job_implemented: false, desktop_job_failed: false }
    },
    credential_status: {
      gemini_api_key: false,
      github_token: false,
      claude_oauth_token: false,
      codex_api_key: false,
      codex_auth_json: false,
      api_token: true
    },
    github_rate_limit: null,
    options: {
      locales: ["en", "de", "la"],
      agent_providers: ["claude"],
      chat_providers: [],
      roles: ["operator"],
      codex_auth_modes: ["api_key"],
      agent_max_turns: { min: 0, max: 1000 },
      clearable_credentials: [],
      auto_approve_modes: [{ value: "never", label: "Never", preview: "No direct rule." }]
    },
    ...overrides
  }
}

function renderRoute(payload = credentialsPayload()) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <CredentialsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AccountSettings ApiTokenPanel", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when rotating a token", async () => {
    renderRoute()

    const rotateButton = await screen.findByRole("button", { name: "Rotate token" })
    fireEvent.click(rotateButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
  })

  it("opens confirm dialog with destructive: true when revoking a token", async () => {
    renderRoute()

    const revokeButton = await screen.findByRole("button", { name: "Revoke" })
    fireEvent.click(revokeButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the rotate API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/credentials/rotate_api_token" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(credentialsPayload({ message: "Token rotated.", new_api_token: "new-tok-123" })))
      }
      return Promise.resolve(jsonResponse(credentialsPayload()))
    })

    renderRoute()

    const rotateButton = await screen.findByRole("button", { name: "Rotate token" })
    fireEvent.click(rotateButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/rotate_api_token",
        expect.objectContaining({ method: "POST" })
      )
    })
  })

  it("calls the revoke API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/credentials/revoke_api_token" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(credentialsPayload({ message: "Token revoked." })))
      }
      return Promise.resolve(jsonResponse(credentialsPayload()))
    })

    renderRoute()

    const revokeButton = await screen.findByRole("button", { name: "Revoke" })
    fireEvent.click(revokeButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/revoke_api_token",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the rotate API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(credentialsPayload()))

    renderRoute()

    const rotateButton = await screen.findByRole("button", { name: "Rotate token" })
    await act(async () => { fireEvent.click(rotateButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/credentials/rotate_api_token",
      expect.anything()
    )
  })

  it("does not call the revoke API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(credentialsPayload()))

    renderRoute()

    const revokeButton = await screen.findByRole("button", { name: "Revoke" })
    await act(async () => { fireEvent.click(revokeButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/credentials/revoke_api_token",
      expect.anything()
    )
  })
})

import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import type { ReactElement } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import { AccountProfileRoute, AgentSettingsRoute, CredentialsRoute, PreferencesRoute } from "./AccountSettings"
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
      locale: "en"
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

function renderRoute(payload = credentialsPayload(), route: ReactElement = <CredentialsRoute />) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        {route}
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

describe("AccountSettings form primitives", () => {
  afterEach(() => vi.restoreAllMocks())

  it("associates profile labels with their controls", async () => {
    renderRoute(credentialsPayload(), <AccountProfileRoute />)

    const displayName = await screen.findByLabelText("Display name")
    const displayNameLabel = screen.getByText("Display name")
    expect(displayName).toHaveAttribute("id")
    expect(displayNameLabel).toHaveAttribute("for", displayName.id)

    const bio = screen.getByLabelText("Profile bio")
    expect(bio.tagName).toBe("TEXTAREA")
    expect(screen.getByText("Profile bio")).toHaveAttribute("for", bio.id)
  })

  it("submits the same profile payload fields through the migrated form primitives", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/credentials" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(credentialsPayload({ message: "Credentials updated." })))
      }

      return Promise.resolve(jsonResponse(credentialsPayload()))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <AccountProfileRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByLabelText("Display name"), { target: { value: "Ada Operator" } })
    fireEvent.change(screen.getByLabelText("First name"), { target: { value: "Ada" } })
    fireEvent.change(screen.getByLabelText("Last name"), { target: { value: "Operator" } })
    fireEvent.change(screen.getByLabelText("Company"), { target: { value: "Analytical Engines" } })
    fireEvent.change(screen.getByLabelText("Location"), { target: { value: "London" } })
    fireEvent.change(screen.getByLabelText("Website"), { target: { value: "https://example.com" } })
    fireEvent.change(screen.getByLabelText("GitHub handle"), { target: { value: "ada" } })
    fireEvent.change(screen.getByLabelText("Avatar URL"), { target: { value: "https://example.com/avatar.png" } })
    fireEvent.change(screen.getByLabelText("Profile bio"), { target: { value: "Keeps forms honest." } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/credentials" && call[1]?.method === "PATCH")
      expect(JSON.parse(String(patchCall?.[1]?.body)).user).toEqual(expect.objectContaining({
        name: "Ada Operator",
        first_name: "Ada",
        last_name: "Operator",
        profile_company: "Analytical Engines",
        profile_location: "London",
        profile_website: "https://example.com",
        github_handle: "ada",
        avatar_url: "https://example.com/avatar.png",
        profile_bio: "Keeps forms honest."
      }))
    })
  })

  it("describes agent settings with Form help text", async () => {
    renderRoute(credentialsPayload(), <AgentSettingsRoute />)

    const fallback = await screen.findByLabelText("Auto-approval fallback")
    const help = screen.getByText("No direct rule.")
    expect(fallback).toHaveAttribute("aria-describedby", help.id)
  })

  it("associates preference labels with select controls", async () => {
    renderRoute(credentialsPayload(), <PreferencesRoute />)

    const language = await screen.findByLabelText("Language")
    expect(language.tagName).toBe("SELECT")
    expect(screen.getByText("Language")).toHaveAttribute("for", language.id)
  })
})

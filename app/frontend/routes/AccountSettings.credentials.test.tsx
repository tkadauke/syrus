import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "../i18n"
import type { CredentialsPayload } from "../api/credentials"
import { CredentialsRoute } from "./AccountSettings"

// The Codex card holds its ActionCable auto-exchange subscription at card
// level; mock the consumer so tests can capture and fire the callback.
const actionCable = vi.hoisted(() => ({
  createSubscription: vi.fn(() => ({ unsubscribe: vi.fn() }))
}))
vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: actionCable.createSubscription
    }
  })
}))

function makePayload(overrides: {
  credential_status?: Partial<CredentialsPayload["credential_status"]>
  chat_providers?: string[]
  admin?: boolean
  codex_auth_mode?: string
} = {}): CredentialsPayload {
  return {
    user: {
      id: 1,
      email_address: "user@example.com",
      name: null,
      first_name: null,
      last_name: null,
      display_name: "user@example.com",
      profile_location: null,
      profile_company: null,
      profile_website: null,
      github_handle: null,
      profile_bio: null,
      avatar_url: null,
      admin: overrides.admin ?? false,
      role: "developer",
      agent_provider: "claude",
      chat_provider: null,
      codex_auth_mode: overrides.codex_auth_mode ?? "api_key",
      opencode_backend: null,
      opencode_model: null,
      opencode_endpoint_url: null,
      agent_max_turns: 200,
      scheduling_paused: false,
      auto_approve_mode: "never",
      locale: "en",
      notification_preferences: {
        desktop_job_implemented: true,
        desktop_job_failed: true
      }
    },
    credential_status: {
      github_token: true,
      claude_oauth_token: true,
      codex_api_key: true,
      codex_auth_json: false,
      opencode_api_key: false,
      gemini_api_key: true,
      api_token: null,
      ...overrides.credential_status
    },
    github_rate_limit: null,
    options: {
      locales: ["en", "de", "la"],
      agent_providers: ["claude", "codex"],
      chat_providers: overrides.chat_providers ?? [],
      roles: ["developer", "product_owner"],
      codex_auth_modes: ["api_key", "chatgpt_login"],
      opencode_backends: ["openai_api", "ollama", "azure_openai"],
      agent_max_turns: { min: 0, max: 1000 },
      clearable_credentials: [],
      auto_approve_modes: [{ value: "never", label: "Never", preview: "No auto-approval." }]
    }
  }
}

// Mirror the real server: the credentials show action never includes a
// mutation `message`, so the stateful mock strips it before serving GETs.
function withoutMessage(payload: CredentialsPayload): CredentialsPayload {
  const { message: _ignored, ...rest } = payload
  return rest
}

// Stateful router: card saves/clears cache a snapshot AND invalidate, so the
// follow-up GET must serve whatever state the last mutation produced.
function mockRoutes(
  initialPayload: CredentialsPayload,
  routes: { clear?: () => Response; patch?: () => Response } = {}
) {
  const state = { payload: initialPayload }
  const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/api/v1/app/credentials") && method === "GET") return jsonResponse(state.payload)
    if (url.endsWith("/api/v1/app/credentials") && method === "PATCH") {
      const response = routes.patch?.() ?? jsonResponse(state.payload)
      state.payload = withoutMessage(JSON.parse(await response.clone().text()) as CredentialsPayload)
      return response
    }
    if (url.endsWith("/clear_credential")) {
      const response = routes.clear?.() ?? jsonResponse(state.payload)
      if (response.ok) state.payload = withoutMessage(JSON.parse(await response.clone().text()) as CredentialsPayload)
      return response
    }
    if (url.endsWith("/test_claude_cli")) return jsonResponse({ credential_test: { credential: "claude_oauth_token", ok: false, message: "Not yet.", details: {} } })
    if (url.endsWith("/codex_oauth_start")) return jsonResponse({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true })
    if (url.endsWith("/codex_oauth_exchange")) return jsonResponse({ credential_test: { credential: "codex_auth_json", ok: true, message: "Codex ChatGPT auth.json is valid.", details: {} }, message: "Codex ChatGPT auth.json is valid." })
    throw new Error(`unexpected fetch: ${method} ${url}`)
  })
  return fetchSpy
}

function renderCredentials() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/credentials"]}>
          <Routes>
            <Route path="/credentials" element={<CredentialsRoute />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("CredentialsRoute (provider cards)", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    actionCable.createSubscription.mockClear()
  })

  it("renders one card per provider from the payload, without a global Save", async () => {
    mockRoutes(makePayload())
    renderCredentials()

    expect(await screen.findByTestId("credential-card-github")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-claude")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-codex")).toBeInTheDocument()
    expect(screen.getByTestId("credential-card-gemini")).toBeInTheDocument()

    // Every card shows its connected state — no password field impersonating
    // a saved secret, and no page-wide Save button for the section.
    expect(screen.getAllByText("Connected")).toHaveLength(4)
    expect(screen.queryByRole("button", { name: "Save" })).not.toBeInTheDocument()
  })

  it("renders a card error inside the failing card, not as a page-top banner stack", async () => {
    mockRoutes(makePayload(), { clear: () => jsonResponse({ error: { message: "Gemini clear exploded." } }, 422) })
    renderCredentials()

    const geminiCard = await screen.findByTestId("credential-card-gemini")
    fireEvent.click(within(geminiCard).getByRole("button", { name: "Clear" }))

    const alert = await within(geminiCard).findByRole("alert")
    expect(alert).toHaveTextContent("Gemini clear exploded.")
    // The other cards stay clean.
    expect(within(screen.getByTestId("credential-card-github")).queryByRole("alert")).not.toBeInTheDocument()
  })

  it("updates card state from the clear response payload (Connected → Not set)", async () => {
    const cleared = makePayload({ credential_status: { gemini_api_key: false } })
    mockRoutes(makePayload(), { clear: () => jsonResponse({ ...cleared, message: "Gemini API key cleared." }) })
    renderCredentials()

    const geminiCard = await screen.findByTestId("credential-card-gemini")
    expect(within(geminiCard).getByText("Connected")).toBeInTheDocument()

    fireEvent.click(within(geminiCard).getByRole("button", { name: "Clear" }))

    await waitFor(() => expect(within(screen.getByTestId("credential-card-gemini")).getByText("Not set")).toBeInTheDocument())
    expect(within(screen.getByTestId("credential-card-gemini")).getByRole("button", { name: "Set up key" })).toBeInTheDocument()
  })

  it("saves the chat provider immediately per-change through a partial PATCH", async () => {
    const fetchSpy = mockRoutes(makePayload({ chat_providers: ["claude", "codex"] }))
    renderCredentials()

    const select = await screen.findByLabelText("Chat provider")
    fireEvent.change(select, { target: { value: "codex" } })

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find(([url, init]) => String(url).endsWith("/api/v1/app/credentials") && init?.method === "PATCH")
      expect(patchCall).toBeTruthy()
      expect(JSON.parse(patchCall?.[1]?.body as string)).toEqual({ user: { chat_provider: "codex" } })
    })
  })

  it("keeps the card's specific notice — the payload's generic message must not overwrite it", async () => {
    const updated = { ...makePayload({ chat_providers: ["claude", "codex"] }), message: "Credentials updated." }
    mockRoutes(makePayload({ chat_providers: ["claude", "codex"] }), { patch: () => jsonResponse(updated) })
    renderCredentials()

    const select = await screen.findByLabelText("Chat provider")
    fireEvent.change(select, { target: { value: "codex" } })

    expect(await screen.findByText("Chat provider saved.")).toBeInTheDocument()
    // The PATCH response's generic "Credentials updated." is stripped before
    // the snapshot is cached, so the payload-message effect stays silent and
    // the specific toast survives.
    await waitFor(() => expect(screen.queryByText("Credentials updated.")).not.toBeInTheDocument())
    expect(screen.getByText("Chat provider saved.")).toBeInTheDocument()
  })

  it("keeps the Codex OAuth callback subscription alive across an auth-mode flip", async () => {
    const chatgpt = makePayload({ codex_auth_mode: "chatgpt_login" })
    const apiKeyMode = makePayload({ codex_auth_mode: "api_key" })
    const fetchSpy = mockRoutes(chatgpt, { patch: () => jsonResponse(apiKeyMode) })
    renderCredentials()

    // ChatGPT mode with no auth.json saved → the authorize flow is visible.
    const codexCard = await screen.findByTestId("credential-card-codex")
    fireEvent.click(within(codexCard).getByRole("button", { name: "Authorize with ChatGPT" }))
    await waitFor(() => expect(actionCable.createSubscription).toHaveBeenCalled())

    // Flip the auth mode mid-authorization: the ChatGPT section unmounts,
    // but the card-level subscription must survive.
    fireEvent.change(within(codexCard).getByLabelText("Codex authentication"), { target: { value: "api_key" } })
    await waitFor(() => expect(within(screen.getByTestId("credential-card-codex")).getByText("A Codex API key is saved.")).toBeInTheDocument())
    expect(within(screen.getByTestId("credential-card-codex")).queryByRole("button", { name: "Authorize with ChatGPT" })).not.toBeInTheDocument()

    // The provider callback arrives late — it must still auto-exchange.
    const callbacks = (actionCable.createSubscription.mock.calls as unknown[][])
      .map((call) => (call[1] as { received?: unknown } | undefined)?.received)
      .filter((received): received is (data: unknown) => void => typeof received === "function")
    expect(callbacks.length).toBeGreaterThan(0)
    callbacks.forEach((received) => received({ type: "codex_oauth.callback", payload: { code: "auto-code" } }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credentials/codex_oauth_exchange",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ code: "auto-code" })
        })
      )
    })
  })

  it("keeps the admin API token panel on the page", async () => {
    mockRoutes(makePayload({ admin: true, credential_status: { api_token: true } }))
    renderCredentials()

    expect(await screen.findByText("API token")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Rotate token" })).toBeInTheDocument()
  })
})

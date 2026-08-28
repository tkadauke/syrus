import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ReactElement } from "react"
import type { CredentialsPayload } from "../../api/credentials"
import { ClaudeCredentialCard, CodexCredentialCard, GeminiCredentialCard, GithubCredentialCard } from "./CredentialCard"

function makePayload(overrides: {
  credential_status?: Partial<CredentialsPayload["credential_status"]>
  codex_auth_mode?: string
  admin?: boolean
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
      agent_max_turns: 200,
      provider_availability_pause_thresholds: { claude: 10, codex: 10 },
      provider_availability_overrides: {},
      scheduling_paused: false,
      auto_approve_mode: "never",
      locale: "en"
    },
    credential_status: {
      github_token: false,
      claude_oauth_token: false,
      codex_api_key: false,
      codex_auth_json: false,
      gemini_api_key: false,
      api_token: null,
      ...overrides.credential_status
    },
    github_rate_limit: null,
    provider_availability: {},
    options: {
      locales: ["en", "de", "la"],
      agent_providers: ["claude", "codex"],
      chat_providers: [],
      roles: ["developer", "product_owner"],
      codex_auth_modes: ["api_key", "chatgpt_login"],
      agent_max_turns: { min: 0, max: 1000 },
      clearable_credentials: [],
      auto_approve_modes: [{ value: "never", label: "Never", preview: "No auto-approval." }]
    }
  }
}

function renderCard(ui: ReactElement, { bootstrap }: { bootstrap?: unknown } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  if (bootstrap) client.setQueryData(["bootstrap"], bootstrap)
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

// Route fetch by path + method, mirroring the app's API layer.
function mockRoutes(routes: {
  test?: () => Response
  clear?: () => Response
  patch?: () => Response
  claudePreflight?: () => Response
  githubProbe?: () => Response
  codexStart?: () => Response
  codexExchange?: () => Response
} = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/test_credential")) return routes.test?.() ?? jsonResponse({ credential_test: { credential: "x", ok: true, message: "OK.", details: {} } })
    if (url.endsWith("/clear_credential")) return routes.clear?.() ?? jsonResponse(makePayload())
    if (url.endsWith("/test_claude_cli")) return routes.claudePreflight?.() ?? jsonResponse({ credential_test: { credential: "claude_oauth_token", ok: false, message: "Not yet.", details: {} } })
    if (url.endsWith("/test_github_token")) return routes.githubProbe?.() ?? jsonResponse({ credential_test: { ok: false, message: "", details: {} } })
    if (url.endsWith("/codex_oauth_start")) return routes.codexStart?.() ?? jsonResponse({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true })
    if (url.endsWith("/codex_oauth_exchange")) return routes.codexExchange?.() ?? jsonResponse({ credential_test: { credential: "codex_auth_json", ok: true, message: "Codex ChatGPT auth.json is valid.", details: {} } })
    if (url.endsWith("/credentials") && method === "GET") return jsonResponse(makePayload())
    if (url.endsWith("/credentials") && method === "PATCH") return routes.patch?.() ?? jsonResponse(makePayload())
    throw new Error(`unexpected fetch: ${method} ${url}`)
  })
}

function patchCalls(fetchSpy: ReturnType<typeof mockRoutes>) {
  return fetchSpy.mock.calls.filter(([url, init]) => String(url).endsWith("/credentials") && init?.method === "PATCH")
}

describe("GithubCredentialCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the guided token step directly when no token is saved", () => {
    mockRoutes()
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload()} />)

    expect(screen.getByText("Not set")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("ghp_…")).toBeInTheDocument()
    expect(screen.getByText("repo")).toBeInTheDocument()
    expect(screen.getByText("workflow")).toBeInTheDocument()
  })

  it("shows a connected summary when set, and Replace reveals the same guided step", () => {
    mockRoutes()
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { github_token: true } })} />)

    expect(screen.getByText("Connected")).toBeInTheDocument()
    expect(screen.getByText(/personal access token is saved/i)).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("ghp_…")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Replace" }))
    expect(screen.getByPlaceholderText("ghp_…")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save token" })).toBeInTheDocument()
  })

  it("tests the SAVED token only via the explicit Test button and shows the result", async () => {
    const fetchSpy = mockRoutes({
      test: () => jsonResponse({ credential_test: { credential: "github_token", ok: true, message: "Token is valid.", details: { login: "octocat", scopes: ["repo", "workflow"] } } })
    })
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { github_token: true } })} />)

    // No probe on mount — saved-credential tests are explicit.
    expect(fetchSpy).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Test" }))
    await waitFor(() => expect(screen.getByText(/Token is valid/)).toBeInTheDocument())
    expect(screen.getByText(/octocat/)).toBeInTheDocument()

    const testCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/test_credential"))
    expect(JSON.parse(testCall?.[1]?.body as string)).toEqual({ credential: "github_token" })
  })

  it("shows GitHub App status from setup_status, with the admin-only setup action", () => {
    mockRoutes()
    const bootstrap = { setup_status: { first_successful_job_completed: true, credential_status: { github: true, github_pat: true, github_app: false, agent: true, active_agent_provider: "claude" } } }
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { github_token: true }, admin: true })} />, { bootstrap })

    expect(screen.getByText("GitHub App not registered")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Set up GitHub App" })).toBeInTheDocument()
  })

  it("hides the GitHub App action from non-admins and shows registered state", () => {
    mockRoutes()
    const registered = { setup_status: { first_successful_job_completed: true, credential_status: { github: true, github_pat: true, github_app: true, agent: true, active_agent_provider: "claude" } } }
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { github_token: true } })} />, { bootstrap: registered })

    expect(screen.getByText("GitHub App registered")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Set up GitHub App" })).not.toBeInTheDocument()
  })
})

describe("ClaudeCredentialCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows the connected summary when set; Replace opens the real connect flow with preflight", async () => {
    const fetchSpy = mockRoutes()
    renderCard(<ClaudeCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { claude_oauth_token: true } })} />)

    expect(screen.getByText("Connected")).toBeInTheDocument()
    expect(screen.getByText(/Claude OAuth token is saved/)).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Replace" }))
    expect(screen.getByRole("button", { name: /Authorize with Claude/ })).toBeInTheDocument()
    // The connect flow preflights the local CLI, exactly like onboarding.
    await waitFor(() => expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith("/test_claude_cli"))).toBe(true))
  })

  it("never spawns the CLI preflight on a plain page view — only after the explicit Connect action", async () => {
    const fetchSpy = mockRoutes()
    renderCard(<ClaudeCredentialCard onNotice={() => {}} payload={makePayload()} />)

    // Unset card shows a CTA, not the mounted connect flow: test_claude_cli
    // runs `claude --print` server-side and must never fire without a click.
    expect(screen.getByRole("button", { name: "Connect Claude" })).toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Connect Claude" }))
    expect(screen.getByRole("button", { name: /Authorize with Claude/ })).toBeInTheDocument()
    await waitFor(() => expect(fetchSpy.mock.calls.some(([url]) => String(url).endsWith("/test_claude_cli"))).toBe(true))
  })

  it("saves a manually pasted token as a partial PATCH containing only that key", async () => {
    const fetchSpy = mockRoutes({ patch: () => jsonResponse(makePayload({ credential_status: { claude_oauth_token: true } })) })
    const onNotice = vi.fn()
    renderCard(<ClaudeCredentialCard onNotice={onNotice} payload={makePayload()} />)

    fireEvent.click(screen.getByRole("button", { name: "Connect Claude" }))
    fireEvent.change(screen.getByLabelText("Claude OAuth token"), { target: { value: "  sk-ant-oat01-abc  " } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Claude token saved."))
    const calls = patchCalls(fetchSpy)
    expect(calls).toHaveLength(1)
    expect(JSON.parse(calls[0][1]?.body as string)).toEqual({ user: { claude_oauth_token: "sk-ant-oat01-abc" } })
  })

  it("never treats a blank manual input as a save (or a clear)", () => {
    const fetchSpy = mockRoutes()
    renderCard(<ClaudeCredentialCard onNotice={() => {}} payload={makePayload()} />)

    fireEvent.click(screen.getByRole("button", { name: "Connect Claude" }))
    const save = screen.getByRole("button", { name: "Save" })
    expect(save).toBeDisabled()
    fireEvent.change(screen.getByLabelText("Claude OAuth token"), { target: { value: "   " } })
    expect(save).toBeDisabled()
    expect(patchCalls(fetchSpy)).toHaveLength(0)
  })

  it("clears only via the explicit Clear action", async () => {
    const fetchSpy = mockRoutes({ clear: () => jsonResponse({ ...makePayload(), message: "Claude OAuth token cleared." }) })
    const onNotice = vi.fn()
    renderCard(<ClaudeCredentialCard onNotice={onNotice} payload={makePayload({ credential_status: { claude_oauth_token: true } })} />)

    fireEvent.click(screen.getByRole("button", { name: "Clear" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Claude OAuth token cleared."))
    const clearCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/clear_credential"))
    expect(JSON.parse(clearCall?.[1]?.body as string)).toEqual({ credential: "claude_oauth_token" })
  })
})

describe("CodexCredentialCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("keeps the auth-mode select inside the card and saves mode changes immediately as a partial PATCH", async () => {
    const fetchSpy = mockRoutes({ patch: () => jsonResponse(makePayload({ codex_auth_mode: "chatgpt_login" })) })
    const onNotice = vi.fn()
    renderCard(<CodexCredentialCard onNotice={onNotice} payload={makePayload()} />)

    fireEvent.change(screen.getByRole("combobox"), { target: { value: "chatgpt_login" } })

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Codex authentication mode saved."))
    const calls = patchCalls(fetchSpy)
    expect(calls).toHaveLength(1)
    expect(JSON.parse(calls[0][1]?.body as string)).toEqual({ user: { codex_auth_mode: "chatgpt_login" } })
  })

  it("saves the API key per-card and blocks blank saves", async () => {
    const fetchSpy = mockRoutes({ patch: () => jsonResponse(makePayload({ credential_status: { codex_api_key: true } })) })
    const onNotice = vi.fn()
    renderCard(<CodexCredentialCard onNotice={onNotice} payload={makePayload()} />)

    const save = screen.getByRole("button", { name: "Save" })
    expect(save).toBeDisabled()

    fireEvent.change(screen.getByLabelText("Codex API key"), { target: { value: "sk-test-123" } })
    fireEvent.click(save)

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Codex credential saved."))
    const calls = patchCalls(fetchSpy)
    expect(calls).toHaveLength(1)
    expect(JSON.parse(calls[0][1]?.body as string)).toEqual({ user: { codex_api_key: "sk-test-123" } })
  })

  it("shows the api-key connected summary with Test/Replace/Clear when saved", () => {
    mockRoutes()
    renderCard(<CodexCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { codex_api_key: true } })} />)

    expect(screen.getByText("Connected")).toBeInTheDocument()
    expect(screen.getByText("A Codex API key is saved.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Test" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Replace" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument()
  })

  it("shows the ChatGPT-login summary when auth.json is saved, with Re-authorize revealing the flow", () => {
    mockRoutes()
    renderCard(<CodexCredentialCard onNotice={() => {}} payload={makePayload({ codex_auth_mode: "chatgpt_login", credential_status: { codex_auth_json: true } })} />)

    expect(screen.getByText("Connected")).toBeInTheDocument()
    expect(screen.getByText(/ChatGPT login \(auth\.json\) is saved/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Re-authorize" }))
    expect(screen.getByRole("button", { name: "Authorize with ChatGPT" })).toBeInTheDocument()
  })

  it("clears the stale card error when a ChatGPT exchange retry succeeds", async () => {
    let exchangeAttempts = 0
    mockRoutes({
      codexExchange: () => {
        exchangeAttempts += 1
        return exchangeAttempts === 1
          ? jsonResponse({ error: { message: "Exchange blew up." } }, 422)
          : jsonResponse({ credential_test: { credential: "codex_auth_json", ok: true, message: "Codex ChatGPT auth.json is valid.", details: {} }, message: "Codex ChatGPT auth.json is valid." })
      }
    })
    const onNotice = vi.fn()
    renderCard(<CodexCredentialCard onNotice={onNotice} payload={makePayload({ codex_auth_mode: "chatgpt_login" })} />)

    fireEvent.change(screen.getByLabelText("ChatGPT authorization code"), { target: { value: "code#1" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))
    expect(await screen.findByRole("alert")).toHaveTextContent("Exchange blew up.")

    fireEvent.change(screen.getByLabelText("ChatGPT authorization code"), { target: { value: "code#2" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Codex ChatGPT auth.json is valid."))
    // The red banner from the failed attempt must not persist over success.
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })
})

describe("card focus management", () => {
  afterEach(() => vi.restoreAllMocks())

  it("moves focus into the GitHub editor on Replace and back to the heading on Cancel", async () => {
    mockRoutes()
    renderCard(<GithubCredentialCard onNotice={() => {}} payload={makePayload({ credential_status: { github_token: true } })} />)

    fireEvent.click(screen.getByRole("button", { name: "Replace" }))
    await waitFor(() => expect(screen.getByPlaceholderText("ghp_…")).toHaveFocus())

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.getByRole("heading", { name: "GitHub" })).toHaveFocus()
  })

  it("focuses the Claude connect flow's first control on Connect and restores heading focus on Cancel", async () => {
    mockRoutes()
    renderCard(<ClaudeCredentialCard onNotice={() => {}} payload={makePayload()} />)

    fireEvent.click(screen.getByRole("button", { name: "Connect Claude" }))
    await waitFor(() => expect(screen.getByRole("button", { name: /Authorize with Claude/ })).toHaveFocus())

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.getByRole("heading", { name: "Claude" })).toHaveFocus()
  })
})

describe("GeminiCredentialCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("offers the staged-validation setup sheet when no key is saved", async () => {
    mockRoutes()
    renderCard(<GeminiCredentialCard onNotice={() => {}} payload={makePayload()} />)

    expect(screen.getByText("Not set")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Set up key" }))

    await waitFor(() => expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument())
    expect(screen.getByPlaceholderText("Paste your Gemini API key here")).toBeInTheDocument()
  })

  it("shows the connected summary with Test, Replace key, and explicit Clear when saved", async () => {
    const fetchSpy = mockRoutes({ clear: () => jsonResponse({ ...makePayload(), message: "Gemini API key cleared." }) })
    const onNotice = vi.fn()
    renderCard(<GeminiCredentialCard onNotice={onNotice} payload={makePayload({ credential_status: { gemini_api_key: true } })} />)

    expect(screen.getByText("Connected")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Replace key" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Clear" }))
    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Gemini API key cleared."))
    const clearCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/clear_credential"))
    expect(JSON.parse(clearCall?.[1]?.body as string)).toEqual({ credential: "gemini_api_key" })
  })
})

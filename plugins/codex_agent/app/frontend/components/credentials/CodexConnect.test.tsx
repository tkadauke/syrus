import { jsonResponse } from "@app/testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CodexConnect } from "./CodexConnect"
import type { CredentialTestResult } from "@app/api/credentials"

// The ChatGPT-login sub-flow holds an ActionCable auto-exchange subscription;
// mock the consumer so tests can capture and fire the callback without ever
// opening a real socket.
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

function renderConnect(props: { onConnected?: (result: CredentialTestResult) => void; secondaryAction?: React.ReactNode } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <CodexConnect onConnected={props.onConnected ?? (() => {})} secondaryAction={props.secondaryAction} />
    </QueryClientProvider>
  )
}

const apiKeyValid: CredentialTestResult = { credential: "codex_api_key", ok: true, message: "Codex API key is valid.", details: {} }
const authJsonValid: CredentialTestResult = { credential: "codex_auth_json", ok: true, message: "Codex ChatGPT auth.json is valid.", details: {} }

function mockRoutes(routes: { patch?: () => Response; test?: () => Response; oauthStart?: () => Response; oauthExchange?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/credentials") && method === "PATCH") return routes.patch?.() ?? jsonResponse({})
    if (url.endsWith("/test_credential")) return routes.test?.() ?? jsonResponse({ credential_test: apiKeyValid })
    if (url.endsWith("/codex_oauth_start")) return routes.oauthStart?.() ?? jsonResponse({ authorize_url: "https://auth.openai.com/oauth/authorize?state=abc", listener_started: true })
    if (url.endsWith("/codex_oauth_exchange")) return routes.oauthExchange?.() ?? jsonResponse({ credential_test: authJsonValid })
    throw new Error(`unexpected fetch: ${method} ${url}`)
  })
}

describe("CodexConnect", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    actionCable.createSubscription.mockClear()
  })

  it("saves and validates an API key, calling onConnected only once the saved key tests OK", async () => {
    const fetchSpy = mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByLabelText("Codex API key"), { target: { value: "sk-test-123" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(apiKeyValid))
    const patchCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/credentials"))
    expect(JSON.parse(patchCall?.[1]?.body as string)).toEqual({ user: { codex_api_key: "sk-test-123", codex_auth_mode: "api_key" } })
  })

  it("surfaces a failed validation without calling onConnected", async () => {
    mockRoutes({ test: () => jsonResponse({ credential_test: { credential: "codex_api_key", ok: false, message: "OpenAI rejected this key.", details: {} } }) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByLabelText("Codex API key"), { target: { value: "sk-bad" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(screen.getByText("OpenAI rejected this key.")).toBeInTheDocument())
    expect(onConnected).not.toHaveBeenCalled()
  })

  it("switches to ChatGPT login, authorizes, and auto-exchanges the callback code", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByRole("combobox"), { target: { value: "chatgpt_login" } })
    fireEvent.click(screen.getByRole("button", { name: "Authorize with ChatGPT" }))
    await waitFor(() => expect(actionCable.createSubscription).toHaveBeenCalled())

    const callback = (actionCable.createSubscription.mock.calls[0] as unknown[])[1] as { received: (data: unknown) => void }
    callback.received({ type: "codex_oauth.callback", payload: { code: "auto-code" } })

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(authJsonValid))
  })

  it("renders the host-provided secondary action", () => {
    mockRoutes()
    renderConnect({ secondaryAction: <button type="button">Cancel</button> })

    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
  })
})

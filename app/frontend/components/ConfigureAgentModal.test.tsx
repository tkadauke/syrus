import { jsonResponse } from "../testSupport"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { resetBackendUpdateStoreForTests, useBackendOutage } from "../hooks/useBackendUpdate"
import { ConfigureAgentModal } from "./ConfigureAgentModal"

function renderModal(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ConfigureAgentModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

const notReady = { credential: "claude_oauth_token", ok: false, message: "Claude is not authenticated on this machine yet.", details: {} }
const ready = { credential: "claude_oauth_token", ok: true, message: "Claude already works on this machine — no token needed.", details: {} }
const tokenValid = { credential: "claude_oauth_token", ok: true, message: "Claude OAuth token is valid.", details: {} }

const minimalCredentials = {
  credential_status: {},
  options: { agent_providers: [], chat_providers: [] },
  user: { agent_provider: "claude" }
}

function mockRoutes(routes: {
  preflight?: () => Response
  start?: () => Response
  exchange?: () => Response
  testGemini?: () => Response
  credentials?: unknown
  patchCredentials?: () => Response
}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/test_claude_cli")) return routes.preflight?.() ?? jsonResponse({ credential_test: notReady })
    if (url.endsWith("/claude_oauth_start")) return routes.start?.() ?? jsonResponse({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" })
    if (url.endsWith("/claude_oauth_exchange")) return routes.exchange?.() ?? jsonResponse({ credential_test: tokenValid })
    if (url.endsWith("/credentials/test_gemini_key")) return routes.testGemini?.() ?? jsonResponse({ credential_test: geminiValid })
    if (url.endsWith("/api/v1/app/credentials") && method === "PATCH") return routes.patchCredentials?.() ?? jsonResponse(routes.credentials ?? minimalCredentials)
    if (url.endsWith("/api/v1/app/credentials")) return jsonResponse(routes.credentials ?? minimalCredentials)
    throw new Error(`unexpected fetch: ${url}`)
  })
}

const geminiValid = { credential: "gemini_api_key", ok: true, message: "Gemini key is valid.", details: { model: "gemini-3.5-flash" } }

describe("ConfigureAgentModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows a Claude tab and a disabled Codex tab", async () => {
    mockRoutes({})
    renderModal()

    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("tab", { name: /Codex/ })).toBeDisabled()
    expect(screen.queryByRole("tab", { name: "Antigravity" })).not.toBeInTheDocument()
    await waitFor(() => expect(window.fetch).toHaveBeenCalled())
  })

  it("preflights and reassures when Claude already works on this machine", async () => {
    mockRoutes({ preflight: () => jsonResponse({ credential_test: ready }) })
    renderModal()

    await waitFor(() => expect(screen.getByText(/already works on this machine/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Skip for now" })).toBeInTheDocument()
  })

  it("opens the authorize URL in a new tab and enables the code field", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes({ start: () => jsonResponse({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" }) })
    renderModal()

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    expect(screen.getByPlaceholderText("paste code here")).toBeDisabled()

    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))

    await waitFor(() => expect(openSpy).toHaveBeenCalledWith("https://claude.ai/oauth/authorize?state=abc", "_blank"))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())
  })

  it("exchanges a pasted code and shows a green check", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = mockRoutes({ exchange: () => jsonResponse({ credential_test: tokenValid }) })
    const onSaved = vi.fn()
    renderModal({ onSaved })

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())

    fireEvent.change(screen.getByPlaceholderText("paste code here"), { target: { value: "the-code#state" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(screen.getByText("Claude OAuth token is valid.")).toBeInTheDocument())
    expect(onSaved).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("button", { name: "Done" })).toBeInTheDocument()

    const exchangeCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/claude_oauth_exchange"))
    expect(JSON.parse(exchangeCall?.[1]?.body as string)).toEqual({ code: "the-code#state" })
  })

  it("auto-exchanges the authorization code when pasted after authorization starts", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = mockRoutes({ exchange: () => jsonResponse({ credential_test: tokenValid }) })
    const onSaved = vi.fn()
    renderModal({ onSaved })

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    const input = await screen.findByPlaceholderText("paste code here")
    await waitFor(() => expect(input).toBeEnabled())

    fireEvent.paste(input, {
      clipboardData: {
        getData: () => "  pasted-code#state  "
      }
    })

    await waitFor(() => expect(screen.getByText("Claude OAuth token is valid.")).toBeInTheDocument())
    expect(onSaved).toHaveBeenCalledTimes(1)

    const exchangeCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/claude_oauth_exchange"))
    expect(JSON.parse(exchangeCall?.[1]?.body as string)).toEqual({ code: "pasted-code#state" })
  })

  it("preserves an in-flight Claude authorization across tab switches", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = mockRoutes({ exchange: () => jsonResponse({ credential_test: tokenValid }) })
    const onSaved = vi.fn()
    renderModal({ onSaved })

    // Start the authorization on the Claude tab.
    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())

    // Visit the Gemini tab and come back: the Claude flow stays mounted
    // (hidden), so authStarted survives — re-clicking Authorize (which would
    // rotate the PKCE verifier and kill the copied code) is not required.
    fireEvent.click(screen.getByRole("tab", { name: /Gemini/ }))
    expect(screen.getByRole("button", { name: /Add Gemini API key/ })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("tab", { name: "Claude" }))

    const input = screen.getByPlaceholderText("paste code here")
    expect(input).toBeEnabled()

    // Pasting the already-copied code still auto-exchanges.
    fireEvent.paste(input, { clipboardData: { getData: () => "kept-code#state" } })
    await waitFor(() => expect(screen.getByText("Claude OAuth token is valid.")).toBeInTheDocument())
    expect(onSaved).toHaveBeenCalledTimes(1)
    // Exactly one claude_oauth_start — no forced re-authorization.
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/claude_oauth_start"))).toHaveLength(1)
  })

  it("makes the Gemini tab selectable and opens the setup sheet from it", async () => {
    mockRoutes({})
    renderModal()

    const geminiTab = screen.getByRole("tab", { name: /Gemini/ })
    expect(geminiTab).not.toBeDisabled()
    expect(geminiTab).toHaveAttribute("aria-selected", "false")

    fireEvent.click(geminiTab)
    expect(geminiTab).toHaveAttribute("aria-selected", "true")

    // The tab reveals a key-entry affordance — the trigger for the nested sheet.
    const addKey = screen.getByRole("button", { name: /Add Gemini API key/ })
    expect(addKey).toBeInTheDocument()

    // Clicking it opens the GeminiSetupSheet, which surfaces the password
    // key input (data-testid'd stage list is unique to that sheet).
    fireEvent.click(addKey)
    await waitFor(() => expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument())
    expect(screen.getByPlaceholderText("Paste your Gemini API key here")).toBeInTheDocument()
  })

  it("shows configured Antigravity and saves it as the default agent provider", async () => {
    const fetchSpy = mockRoutes({
      credentials: {
        credential_status: { gemini_api_key: true },
        options: { agent_providers: ["claude", "agy"], chat_providers: ["agy"] },
        user: { agent_provider: "claude" }
      }
    })
    const onSaved = vi.fn()
    renderModal({ onSaved })

    const agyTab = await screen.findByRole("tab", { name: "Antigravity" })
    fireEvent.click(agyTab)

    expect(screen.getByText(/Antigravity is ready for agent and chat runs/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Use Antigravity" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find(([url, init]) => String(url).endsWith("/api/v1/app/credentials") && init?.method === "PATCH")
      expect(patchCall).toBeTruthy()
      expect(JSON.parse(patchCall?.[1]?.body as string)).toEqual({ user: { agent_provider: "agy" } })
    })
    expect(onSaved).toHaveBeenCalledTimes(1)
  })

  it("keeps the modal open when Escape dismisses the nested Gemini sheet", async () => {
    mockRoutes({})
    const onClose = vi.fn()
    renderModal({ onClose })

    fireEvent.click(screen.getByRole("tab", { name: /Gemini/ }))
    fireEvent.click(screen.getByRole("button", { name: /Add Gemini API key/ }))
    await waitFor(() => expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument())

    // Escape must close only the sheet — the outer modal's own Escape handler
    // is guarded while the sheet is open, so onClose (which unmounts the whole
    // modal) must NOT fire.
    fireEvent.keyDown(document, { key: "Escape" })

    await waitFor(() => expect(screen.queryByTestId("gemini-validation-stages")).not.toBeInTheDocument())
    expect(onClose).not.toHaveBeenCalled()
    // Back on the Gemini tab, ready to reopen the sheet.
    expect(screen.getByRole("button", { name: /Add Gemini API key/ })).toBeInTheDocument()
  })

  it("shows the configured state and calls onSaved after a successful Gemini key validation", async () => {
    mockRoutes({})
    const onSaved = vi.fn()
    renderModal({ onSaved })

    fireEvent.click(screen.getByRole("tab", { name: /Gemini/ }))
    fireEvent.click(screen.getByRole("button", { name: /Add Gemini API key/ }))
    const input = await screen.findByPlaceholderText("Paste your Gemini API key here")

    fireEvent.change(input, { target: { value: "AIzaSyA1234567890abcdefghijklmnop" } })
    fireEvent.click(screen.getByRole("button", { name: "Validate & save" }))

    // onConfigured (which calls onSaved) is the definitive signal the sheet
    // finished — NOT the "Gemini is set up" substring, which the sheet's own
    // saved message also contains during its closing pause. Wait on onSaved.
    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1), { timeout: 5000 })
    // The modal now renders its configured state (unique copy) + Done.
    expect(screen.getByText(/walkthrough videos will be analyzed automatically/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Done" })).toBeInTheDocument()
  }, 10000)

  it("surfaces an exchange error and stays open", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes({ exchange: () => jsonResponse({ error: { message: "Code expired." } }, 422) })
    renderModal()

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())

    fireEvent.change(screen.getByPlaceholderText("paste code here"), { target: { value: "bad" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(screen.getByText("Code expired.")).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: "Done" })).not.toBeInTheDocument()
  })

  it("shows the updating note, defers the preflight during the outage, and retries when it clears", async () => {
    // A rejected preflight during the outage would silently drop the
    // "Claude already connected" confirmation and re-run the full authorize
    // walkthrough — the same false-from-failure class as the GitHub modal.
    let pushState: ((state: unknown) => void) | undefined
    window.syrusShell = {
      getState: vi.fn().mockResolvedValue({
        updateReadyVersion: null,
        claudeDetected: false,
        skillInstalled: false,
        skillOfferDismissed: true,
        backendUpdate: { phase: "migrating", percent: null, outage: true }
      }),
      onStateChanged: vi.fn().mockImplementation((callback: (state: unknown) => void) => {
        pushState = callback
        return () => {}
      }),
      relaunchToUpdate: vi.fn(),
      installSkill: vi.fn(),
      dismissSkillOffer: vi.fn()
    }
    resetBackendUpdateStoreForTests()

    // Warm the shared store before the modal mounts — in the real app it has
    // been subscribed since app load (ShellNotices), so the outage is already
    // known when the modal opens.
    function Warm() {
      return <span data-testid="warm">{String(useBackendOutage())}</span>
    }
    const warm = render(<Warm />)
    await waitFor(() => expect(screen.getByTestId("warm")).toHaveTextContent("true"))
    warm.unmount()

    const fetchSpy = mockRoutes({ preflight: () => jsonResponse({ credential_test: ready }) })
    renderModal()

    expect(await screen.findByText(/The Syrus backend is updating/)).toBeInTheDocument()
    // The authorize walkthrough is replaced, and the doomed preflight call is
    // deferred entirely.
    expect(screen.queryByRole("button", { name: /Authorize with Claude/ })).not.toBeInTheDocument()
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/test_claude_cli"))).toHaveLength(0)

    // The outage clears → the preflight fires and the ambient confirmation
    // the failure would have swallowed appears.
    act(() => {
      pushState?.({
        updateReadyVersion: null,
        claudeDetected: false,
        skillInstalled: false,
        skillOfferDismissed: true,
        backendUpdate: null
      })
    })
    await waitFor(() => expect(screen.getByText(/already works on this machine/)).toBeInTheDocument())
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/test_claude_cli"))).toHaveLength(1)

    delete window.syrusShell
    resetBackendUpdateStoreForTests()
  })
})

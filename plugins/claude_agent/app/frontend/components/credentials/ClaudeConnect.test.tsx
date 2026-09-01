import { jsonResponse } from "@app/testSupport"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { resetBackendUpdateStoreForTests, useBackendOutage } from "@app/hooks/useBackendUpdate"
import { ClaudeConnect } from "./ClaudeConnect"
import type { CredentialTestResult } from "@app/api/credentials"

function renderConnect(props: { onConnected?: (result: CredentialTestResult) => void; onPreflight?: (ready: boolean) => void; secondaryAction?: React.ReactNode } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ClaudeConnect onConnected={props.onConnected ?? (() => {})} onPreflight={props.onPreflight} secondaryAction={props.secondaryAction} />
    </QueryClientProvider>
  )
}

const notReady = { credential: "claude_oauth_token", ok: false, message: "Claude is not authenticated on this machine yet.", details: {} }
const ready = { credential: "claude_oauth_token", ok: true, message: "Claude already works on this machine — no token needed.", details: {} }
const tokenValid = { credential: "claude_oauth_token", ok: true, message: "Claude OAuth token is valid.", details: {} }

function mockRoutes(routes: { preflight?: () => Response; start?: () => Response; exchange?: () => Response }) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input) => {
    const url = String(input)
    if (url.endsWith("/test_claude_cli")) return routes.preflight?.() ?? jsonResponse({ credential_test: notReady })
    if (url.endsWith("/claude_oauth_start")) return routes.start?.() ?? jsonResponse({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" })
    if (url.endsWith("/claude_oauth_exchange")) return routes.exchange?.() ?? jsonResponse({ credential_test: tokenValid })
    throw new Error(`unexpected fetch: ${url}`)
  })
}

describe("ClaudeConnect", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("preflights on mount and reassures when Claude already works, reporting readiness upward", async () => {
    mockRoutes({ preflight: () => jsonResponse({ credential_test: ready }) })
    const onPreflight = vi.fn()
    renderConnect({ onPreflight })

    await waitFor(() => expect(screen.getByText(/already works on this machine/)).toBeInTheDocument())
    expect(onPreflight).toHaveBeenCalledWith(true)
  })

  it("reports not-ready when the preflight finds no ambient login", async () => {
    mockRoutes({})
    const onPreflight = vi.fn()
    renderConnect({ onPreflight })

    await waitFor(() => expect(onPreflight).toHaveBeenCalledWith(false))
    expect(screen.queryByText(/already works on this machine/)).not.toBeInTheDocument()
  })

  it("opens the authorize URL in a new tab and enables the code field", async () => {
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes({ start: () => jsonResponse({ authorize_url: "https://claude.ai/oauth/authorize?state=abc" }) })
    renderConnect()

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    expect(screen.getByPlaceholderText("paste code here")).toBeDisabled()

    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))

    await waitFor(() => expect(openSpy).toHaveBeenCalledWith("https://claude.ai/oauth/authorize?state=abc", "_blank"))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())
  })

  it("auto-exchanges the authorization code when pasted after authorization starts", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    const fetchSpy = mockRoutes({ exchange: () => jsonResponse({ credential_test: tokenValid }) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    const input = await screen.findByPlaceholderText("paste code here")
    await waitFor(() => expect(input).toBeEnabled())

    fireEvent.paste(input, {
      clipboardData: {
        getData: () => "  pasted-code#state  "
      }
    })

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(tokenValid))
    const exchangeCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/claude_oauth_exchange"))
    expect(JSON.parse(exchangeCall?.[1]?.body as string)).toEqual({ code: "pasted-code#state" })
  })

  it("exchanges a typed code through the Connect button", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes({ exchange: () => jsonResponse({ credential_test: tokenValid }) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())

    fireEvent.change(screen.getByPlaceholderText("paste code here"), { target: { value: "the-code#state" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(tokenValid))
  })

  it("surfaces an exchange error without calling onConnected", async () => {
    vi.spyOn(window, "open").mockReturnValue({} as Window)
    mockRoutes({ exchange: () => jsonResponse({ error: { message: "Code expired." } }, 422) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    await waitFor(() => expect(screen.queryByText(/Checking for an existing Claude login/)).not.toBeInTheDocument())
    fireEvent.click(screen.getByRole("button", { name: /Authorize with Claude/ }))
    await waitFor(() => expect(screen.getByPlaceholderText("paste code here")).toBeEnabled())

    fireEvent.change(screen.getByPlaceholderText("paste code here"), { target: { value: "bad" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(screen.getByText("Code expired.")).toBeInTheDocument())
    expect(onConnected).not.toHaveBeenCalled()
  })

  it("renders the host-provided secondary action next to Connect", async () => {
    mockRoutes({})
    renderConnect({ secondaryAction: <button type="button">Cancel</button> })

    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
    await waitFor(() => expect(window.fetch).toHaveBeenCalled())
  })

  it("defers the preflight and shows the updating note during a backend outage, retrying when it clears", async () => {
    // A rejected preflight during the container-swap window would silently
    // drop the "Claude already works" confirmation and walk the user through
    // re-authorizing credentials that sit safely in the DB — in BOTH hosts
    // (the onboarding modal and the credentials card's expanded state).
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

    // Warm the shared store before mounting — in the real app it has been
    // subscribed since app load (ShellNotices), so the outage is already
    // known when the flow appears.
    function Warm() {
      return <span data-testid="warm">{String(useBackendOutage())}</span>
    }
    const warm = render(<Warm />)
    await waitFor(() => expect(screen.getByTestId("warm")).toHaveTextContent("true"))
    warm.unmount()

    const fetchSpy = mockRoutes({ preflight: () => jsonResponse({ credential_test: ready }) })
    renderConnect({ secondaryAction: <button type="button">Cancel</button> })

    expect(await screen.findByText(/The Syrus backend is updating/)).toBeInTheDocument()
    // The authorize walkthrough is replaced (the host's escape hatch stays),
    // and the doomed preflight call is deferred entirely.
    expect(screen.queryByRole("button", { name: /Authorize with Claude/ })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/test_claude_cli"))).toHaveLength(0)

    // The outage clears → the preflight fires exactly once and the ambient
    // confirmation the failure would have swallowed appears.
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

import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConfigureAgentModal } from "./ConfigureAgentModal"

function renderModal(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ConfigureAgentModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
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
    if (url.endsWith("/api/v1/app/credentials")) return jsonResponse({ credential_status: {} })
    throw new Error(`unexpected fetch: ${url}`)
  })
}

describe("ConfigureAgentModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows a Claude tab and a disabled Codex tab", async () => {
    mockRoutes({})
    renderModal()

    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("tab", { name: /Codex/ })).toBeDisabled()
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

    await waitFor(() => expect(openSpy).toHaveBeenCalledWith("https://claude.ai/oauth/authorize?state=abc", "_blank", expect.any(String)))
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
})

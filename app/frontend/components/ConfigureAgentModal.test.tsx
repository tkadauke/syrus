import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConfigureAgentModal } from "./ConfigureAgentModal"
import { connectOnboardingProvider } from "../api/credentials"

// The four real plugin connect panels (ClaudeConnect, CodexConnect,
// AgyConnect, MuseConnect) each have their own thorough test suite next to
// their component. Stubbing AgentProviderConnectPanel here keeps this file
// focused on what ConfigureAgentModal itself owns: enumerating tabs from
// pluginAgentProviderConnectPanelProviders() and reacting to a connected
// provider — not re-testing every provider's OAuth/API-key flow.
vi.mock("./AgentProviderConnectPanel", () => ({
  AgentProviderConnectPanel: ({ provider, onSaved }: { provider: string; onSaved?: () => void }) => (
    <div>
      <p>connect-panel:{provider}</p>
      <button onClick={() => onSaved?.()} type="button">
        Simulate connect ({provider})
      </button>
    </div>
  )
}))

vi.mock("../api/credentials", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/credentials")>()
  return { ...actual, connectOnboardingProvider: vi.fn() }
})

const mockedConnectOnboardingProvider = vi.mocked(connectOnboardingProvider)

function renderModal(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ConfigureAgentModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

describe("ConfigureAgentModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("enumerates a tab for every plugin-registered agent-provider connect panel, plus Gemini", () => {
    mockedConnectOnboardingProvider.mockResolvedValue({} as never)
    renderModal()

    // The four bundled agent-provider plugins (claude, codex, agy, muse) all
    // ship a real connect panel and must all be reachable during onboarding
    // regardless of their plugin's enabled state — no "Coming soon" tab and
    // no gate hiding a tab until some other credential exists.
    expect(screen.getByRole("tab", { name: "Claude" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Codex" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Antigravity" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Muse" })).toBeInTheDocument()
    expect(screen.getByRole("tab", { name: "Gemini" })).toBeInTheDocument()
    expect(screen.queryByText(/Soon/)).not.toBeInTheDocument()
    expect(screen.getAllByRole("tab").every((tab) => !tab.hasAttribute("disabled"))).toBe(true)
  })

  it("defaults to the Claude tab and renders only the active provider's connect panel", () => {
    renderModal()

    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByText("connect-panel:claude")).toBeInTheDocument()
    expect(screen.queryByText("connect-panel:codex")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("tab", { name: "Codex" }))

    expect(screen.getByRole("tab", { name: "Codex" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "false")
    expect(screen.getByText("connect-panel:codex")).toBeInTheDocument()
    expect(screen.queryByText("connect-panel:claude")).not.toBeInTheDocument()
  })

  it("enables the connected provider's plugin when its connect panel reports success", async () => {
    mockedConnectOnboardingProvider.mockResolvedValue({} as never)
    const onSaved = vi.fn()
    renderModal({ onSaved })

    fireEvent.click(screen.getByRole("tab", { name: "Antigravity" }))
    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (agy)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("agy"))
    expect(mockedConnectOnboardingProvider).toHaveBeenCalledTimes(1)
    expect(onSaved).toHaveBeenCalledTimes(1)
  })

  it("scopes the auto-enable call to whichever provider tab was connected", async () => {
    mockedConnectOnboardingProvider.mockResolvedValue({} as never)
    renderModal()

    fireEvent.click(screen.getByRole("tab", { name: "Muse" }))
    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (muse)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("muse"))
    expect(mockedConnectOnboardingProvider).not.toHaveBeenCalledWith("claude")
  })

  it("makes the Gemini tab selectable and opens the setup sheet from it", async () => {
    renderModal()

    const geminiTab = screen.getByRole("tab", { name: "Gemini" })
    expect(geminiTab).not.toBeDisabled()
    expect(geminiTab).toHaveAttribute("aria-selected", "false")

    fireEvent.click(geminiTab)
    expect(geminiTab).toHaveAttribute("aria-selected", "true")

    const addKey = screen.getByRole("button", { name: /Add Gemini API key/ })
    expect(addKey).toBeInTheDocument()

    fireEvent.click(addKey)
    await waitFor(() => expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument())
    expect(screen.getByPlaceholderText("Paste your Gemini API key here")).toBeInTheDocument()
  })

  it("keeps the modal open when Escape dismisses the nested Gemini sheet", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })

    fireEvent.click(screen.getByRole("tab", { name: "Gemini" }))
    fireEvent.click(screen.getByRole("button", { name: /Add Gemini API key/ }))
    await waitFor(() => expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument())

    fireEvent.keyDown(document, { key: "Escape" })

    await waitFor(() => expect(screen.queryByTestId("gemini-validation-stages")).not.toBeInTheDocument())
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole("button", { name: /Add Gemini API key/ })).toBeInTheDocument()
  })

  it("shows the configured state and calls onSaved after a successful Gemini key validation", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const url = String(input)
      const method = init?.method ?? "GET"
      if (url.endsWith("/credentials/test_gemini_key")) {
        return jsonResponse({
          credential_test: { credential: "gemini_api_key", ok: true, message: "Gemini key is valid.", details: { model: "gemini-3.5-flash" } }
        })
      }
      if (url.endsWith("/api/v1/app/credentials") && method === "PATCH") {
        return jsonResponse({ credential_status: {}, options: { agent_providers: [], chat_providers: [] }, user: { agent_provider: "claude" } })
      }
      throw new Error(`unexpected fetch: ${url}`)
    })
    const onSaved = vi.fn()
    renderModal({ onSaved })

    fireEvent.click(screen.getByRole("tab", { name: "Gemini" }))
    fireEvent.click(screen.getByRole("button", { name: /Add Gemini API key/ }))
    const input = await screen.findByPlaceholderText("Paste your Gemini API key here")

    fireEvent.change(input, { target: { value: "AIzaSyA1234567890abcdefghijklmnop" } })
    fireEvent.click(screen.getByRole("button", { name: "Validate & save" }))

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1), { timeout: 5000 })
    expect(screen.getByText(/walkthrough videos will be analyzed automatically/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Done" })).toBeInTheDocument()
    fetchSpy.mockRestore()
  }, 10000)
})

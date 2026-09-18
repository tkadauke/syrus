import { useEffect } from "react"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConfigureAgentModal } from "./ConfigureAgentModal"
import { connectOnboardingProvider } from "../api/credentials"

const mountSpy = vi.hoisted(() => vi.fn())

// The four real plugin connect panels (ClaudeConnect, CodexConnect,
// AgyConnect, MuseConnect) each have their own thorough test suite next to
// their component. Stubbing AgentProviderConnectPanel here keeps this file
// focused on what ConfigureAgentModal itself owns: enumerating tabs from
// pluginAgentProviderConnectPanelProviders(), keeping a visited provider's
// panel mounted across tab switches, and reacting to a connected provider —
// not re-testing every provider's OAuth/API-key flow. mountSpy records every
// real mount (not every render) so tests can prove a tab switch hides a
// panel instead of unmounting it, the same guarantee ClaudeConnect's OAuth
// flow depends on to survive a Claude <-> Gemini (or Claude <-> Codex) switch.
vi.mock("./AgentProviderConnectPanel", () => ({
  AgentProviderConnectPanel: ({ provider, onSaved }: { provider: string; onSaved?: () => void }) => {
    useEffect(() => {
      mountSpy(provider)
    }, [])
    return (
      <div>
        <p>connect-panel:{provider}</p>
        <button onClick={() => onSaved?.()} type="button">
          Simulate connect ({provider})
        </button>
      </div>
    )
  }
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
    mountSpy.mockClear()
  })

  it("enumerates a tab for every plugin-registered agent-provider connect panel, ordered popular-to-less-popular", () => {
    mockedConnectOnboardingProvider.mockResolvedValue({} as never)
    renderModal()

    // The four bundled agent-provider plugins (claude, codex, agy, muse) all
    // ship a real connect panel and must all be reachable during onboarding
    // regardless of their plugin's enabled state — no "Coming soon" tab and
    // no gate hiding a tab until some other credential exists. Gemini isn't
    // an agent provider (it only powers walkthrough-video analysis) and has
    // no tab here.
    expect(screen.getAllByRole("tab").map((tab) => tab.textContent)).toEqual([
      "Claude", "Codex", "Antigravity", "Muse"
    ])
    expect(screen.queryByText(/Soon/)).not.toBeInTheDocument()
    expect(screen.getAllByRole("tab").every((tab) => !tab.hasAttribute("disabled"))).toBe(true)
  })

  it("defaults to the Claude tab and shows only the active provider's connect panel", () => {
    renderModal()

    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByText("connect-panel:claude")).toBeVisible()

    fireEvent.click(screen.getByRole("tab", { name: "Codex" }))

    expect(screen.getByRole("tab", { name: "Codex" })).toHaveAttribute("aria-selected", "true")
    expect(screen.getByRole("tab", { name: "Claude" })).toHaveAttribute("aria-selected", "false")
    expect(screen.getByText("connect-panel:codex")).toBeVisible()
    expect(screen.getByText("connect-panel:claude")).not.toBeVisible()
  })

  it("never mounts a provider's connect panel until its tab has been opened", () => {
    renderModal()

    expect(mountSpy).toHaveBeenCalledWith("claude")
    expect(mountSpy).not.toHaveBeenCalledWith("codex")
    expect(mountSpy).not.toHaveBeenCalledWith("agy")
    expect(mountSpy).not.toHaveBeenCalledWith("muse")
  })

  it("keeps a visited provider's connect panel mounted (hidden, not unmounted) across tab switches", () => {
    // Regression coverage for the Claude OAuth tab-flip bug: unmounting a
    // connect panel mid-flow resets its local authStarted/pasted-code state,
    // and for Claude specifically can force a re-Authorize that rotates the
    // session's PKCE verifier, invalidating a code the operator already
    // copied. mountSpy firing only once per provider — even after visiting
    // it, switching away, and switching back — proves the panel was hidden
    // rather than unmounted and remounted.
    renderModal()

    fireEvent.click(screen.getByRole("tab", { name: "Codex" }))
    fireEvent.click(screen.getByRole("tab", { name: "Antigravity" }))
    fireEvent.click(screen.getByRole("tab", { name: "Claude" }))

    expect(mountSpy.mock.calls.filter(([provider]) => provider === "claude")).toHaveLength(1)
    expect(mountSpy.mock.calls.filter(([provider]) => provider === "codex")).toHaveLength(1)
    expect(screen.getByText("connect-panel:claude")).toBeVisible()
    expect(screen.getByText("connect-panel:codex")).not.toBeVisible()
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

  it("surfaces a warning when the auto-enable call fails, without blocking the connected state", async () => {
    mockedConnectOnboardingProvider.mockRejectedValue(new Error("boom"))
    const onSaved = vi.fn()
    renderModal({ onSaved })

    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (claude)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("claude"))
    await waitFor(() => expect(screen.getByText(/couldn't enable this provider automatically/)).toBeInTheDocument())
    // The connect panel's own success handling (onSaved) already fired —
    // the auto-enable failure is a secondary, non-blocking warning.
    expect(onSaved).toHaveBeenCalledTimes(1)
  })

  it("clears a stale auto-enable warning when switching tabs", async () => {
    mockedConnectOnboardingProvider.mockRejectedValue(new Error("boom"))
    renderModal()

    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (claude)" }))
    await waitFor(() => expect(screen.getByText(/couldn't enable this provider automatically/)).toBeInTheDocument())

    fireEvent.click(screen.getByRole("tab", { name: "Codex" }))

    expect(screen.queryByText(/couldn't enable this provider automatically/)).not.toBeInTheDocument()
  })
})

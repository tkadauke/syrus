import { useEffect } from "react"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { OnboardingRoute } from "../routes/Onboarding"
import { ConfigureAgentModal } from "./ConfigureAgentModal"
import { connectOnboardingProvider } from "../api/credentials"

const mountSpy = vi.hoisted(() => vi.fn())
const panelPropsSpy = vi.hoisted(() => vi.fn())

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
  AgentProviderConnectPanel: ({ provider, onSaved, deferBootstrapRefresh }: { provider: string; onSaved?: () => Promise<void> | void; deferBootstrapRefresh?: boolean }) => {
    useEffect(() => {
      mountSpy(provider)
    }, [])
    panelPropsSpy({ provider, deferBootstrapRefresh })
    return (
      <div>
        <p>connect-panel:{provider}</p>
        <button onClick={() => void Promise.resolve(onSaved?.()).catch(() => {})} type="button">
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
  return {
    client,
    ...render(
      <QueryClientProvider client={client}>
        <ConfigureAgentModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
      </QueryClientProvider>
    )
  }
}

function renderOnboardingConnection(loadBootstrap: () => Promise<BootstrapPayload>, initialBootstrap: BootstrapPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

  function Harness() {
    const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: loadBootstrap, initialData: initialBootstrap })
    return (
      <MemoryRouter>
        <OnboardingRoute bootstrap={bootstrap.data} />
        <ConfigureAgentModal onClose={() => {}} />
      </MemoryRouter>
    )
  }

  return render(
    <QueryClientProvider client={client}>
      <Harness />
    </QueryClientProvider>
  )
}

function onboardingBootstrap(provider: string, agentConfigured: boolean, providerLabel: string): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      display_name: "Operator",
      admin: true,
      agent_provider: provider
    },
    setup_status: {
      first_epic_landed: false,
      onboarding_chat_started: false,
      credential_status: {
        github: true,
        github_pat: true,
        github_app: true,
        agent: agentConfigured,
        active_agent_provider: provider,
        active_agent_provider_label: providerLabel
      },
      repository_configured: false,
      first_epic_created: false,
      first_epic_started: false,
      counts: { repositories: 0 }
    }
  } as BootstrapPayload
}

describe("ConfigureAgentModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    mountSpy.mockClear()
    panelPropsSpy.mockClear()
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
    expect(screen.getAllByRole("tab").map((tab) => tab.textContent)).toEqual(["Claude", "Codex", "Antigravity", "Muse"])
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

  it("completes connection and refreshes credentials and bootstrap only after onboarding connect succeeds", async () => {
    let resolveConnect: (value: never) => void = () => {}
    mockedConnectOnboardingProvider.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveConnect = resolve
        })
    )
    const onSaved = vi.fn()
    const { client } = renderModal({ onSaved })
    const invalidateSpy = vi.spyOn(client, "invalidateQueries")

    fireEvent.click(screen.getByRole("tab", { name: "Antigravity" }))
    expect(panelPropsSpy).toHaveBeenCalledWith({ provider: "agy", deferBootstrapRefresh: true })
    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (agy)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("agy"))
    expect(mockedConnectOnboardingProvider).toHaveBeenCalledTimes(1)
    expect(onSaved).not.toHaveBeenCalled()
    expect(invalidateSpy).not.toHaveBeenCalled()

    resolveConnect({} as never)

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1))
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["credentials"] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["bootstrap"] })
  })

  it("keeps the connected provider complete after bootstrap refetch and a fresh onboarding mount", async () => {
    let serverBootstrap = onboardingBootstrap("claude", false, "Claude Code")
    const loadBootstrap = vi.fn(() => Promise.resolve(serverBootstrap))
    mockedConnectOnboardingProvider.mockImplementation(async (provider) => {
      serverBootstrap = onboardingBootstrap(provider, true, "Muse Code")
      return {} as never
    })

    const firstMount = renderOnboardingConnection(loadBootstrap, serverBootstrap)
    expect(screen.getByRole("button", { name: "Configure agent" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("tab", { name: "Muse" }))
    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (muse)" }))

    expect(await screen.findByText("Muse Code is ready for runs.")).toBeInTheDocument()
    expect(loadBootstrap).toHaveBeenCalledTimes(2)

    firstMount.unmount()
    renderOnboardingConnection(loadBootstrap, serverBootstrap)

    expect(await screen.findByText("Muse Code is ready for runs.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Edit agent settings" })).toBeInTheDocument()
    expect(loadBootstrap).toHaveBeenCalledTimes(3)
  })

  it("scopes the auto-enable call to whichever provider tab was connected", async () => {
    mockedConnectOnboardingProvider.mockResolvedValue({} as never)
    renderModal()

    fireEvent.click(screen.getByRole("tab", { name: "Muse" }))
    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (muse)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("muse"))
    expect(mockedConnectOnboardingProvider).not.toHaveBeenCalledWith("claude")
  })

  it("surfaces a warning and does not complete onboarding when the onboarding connect call fails", async () => {
    mockedConnectOnboardingProvider.mockRejectedValue(new Error("boom"))
    const onSaved = vi.fn()
    renderModal({ onSaved })

    fireEvent.click(screen.getByRole("button", { name: "Simulate connect (claude)" }))

    await waitFor(() => expect(mockedConnectOnboardingProvider).toHaveBeenCalledWith("claude"))
    await waitFor(() => expect(screen.getByText(/couldn't enable this provider automatically/)).toBeInTheDocument())
    expect(onSaved).not.toHaveBeenCalled()
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

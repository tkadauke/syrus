import { act, cleanup, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { App } from "./App"

type Credentials = { url: string; token: string }

function stubBridge(initialCredentials: Credentials | null) {
  let savedListener: ((credentials: Credentials) => void) | undefined
  let clearedListener: (() => void) | undefined
  const unsubscribeSaved = vi.fn()
  const unsubscribeCleared = vi.fn()

  const bridge = {
    platform: "darwin",
    getAppVersion: vi.fn().mockResolvedValue("1.0.0"),
    getCredentials: vi.fn().mockResolvedValue(initialCredentials),
    getDesktopSettings: vi.fn().mockResolvedValue({ localProjectsRoot: "", localRepoPaths: {} }),
    getGlobalHotkey: vi.fn().mockResolvedValue(""),
    getServerUrl: vi.fn().mockResolvedValue("https://old.example"),
    onCredentialsSaved: vi.fn((listener: (credentials: Credentials) => void) => {
      savedListener = listener
      return unsubscribeSaved
    }),
    onCredentialsCleared: vi.fn((listener: () => void) => {
      clearedListener = listener
      return unsubscribeCleared
    }),
    fetchInboxJobs: vi.fn().mockResolvedValue([]),
    syrusCliStatus: vi.fn().mockResolvedValue({ available: true, bundledAvailable: true }),
    fetchBootstrap: vi.fn().mockResolvedValue({ current_user: { admin: false }, unread_notifications_count: 0 }),
    fetchNotificationUnreadCount: vi.fn().mockResolvedValue(0),
    localStatus: vi.fn().mockResolvedValue(null),
    onNotificationEvent: vi.fn(() => vi.fn()),
    onNavigateToJob: vi.fn(() => vi.fn()),
    onDesktopSettingsUpdated: vi.fn(() => vi.fn())
  }

  ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = bridge
  return {
    bridge,
    emitSaved: (credentials: Credentials) => savedListener?.(credentials),
    emitCleared: () => clearedListener?.()
  }
}

function renderApp(client: QueryClient) {
  return render(
    <QueryClientProvider client={client}>
      <App />
    </QueryClientProvider>
  )
}

describe("desktop credential events", () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    window.history.replaceState({}, "", "/")
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("leaves the stale inbox and clears cached instance data when credentials are cleared", async () => {
    const events = stubBridge({ url: "https://old.example", token: "old-token" })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["instance-data"], "stale")
    renderApp(client)

    expect(await screen.findByText("https://old.example")).toBeDefined()

    act(() => events.emitCleared())

    expect(await screen.findByRole("heading", { name: "Connect Syrus" })).toBeDefined()
    expect(client.getQueryData(["instance-data"])).toBeUndefined()
  })

  it("loads newly saved credentials and retargets the tray to the new instance", async () => {
    const events = stubBridge(null)
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["instance-data"], "stale")
    renderApp(client)

    expect(await screen.findByRole("heading", { name: "Connect Syrus" })).toBeDefined()

    act(() => events.emitSaved({ url: "https://new.example", token: "new-token" }))

    await waitFor(() => expect(screen.getByText("https://new.example")).toBeDefined())
    expect(client.getQueryData(["instance-data"])).toBeUndefined()
  })

  it("replaces the displayed instance when credentials switch", async () => {
    const events = stubBridge({ url: "https://old.example", token: "old-token" })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderApp(client)

    expect(await screen.findByText("https://old.example")).toBeDefined()

    act(() => events.emitSaved({ url: "https://new.example", token: "new-token" }))

    await waitFor(() => expect(screen.getByText("https://new.example")).toBeDefined())
    expect(screen.queryByText("https://old.example")).toBeNull()
  })
})

import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import {
  type PlatformIdentitiesPayload,
  type PlatformIdentity,
  type AvailablePlatform
} from "../api/platformIdentities"
import { useConfirm } from "../hooks/useConfirm"
import { jsonResponse } from "../testSupport"
import { ConnectedPlatformsRoute } from "./ConnectedPlatforms"

let receivedHandler: ((data: unknown) => void) | undefined

vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: (_params: unknown, handlers: { received: (data: unknown) => void }) => {
        receivedHandler = handlers.received
        return { unsubscribe: vi.fn() }
      }
    }
  })
}))

vi.mock("../hooks/useConfirm", () => ({
  useConfirm: vi.fn()
}))

function platformIdentitiesPayload(overrides: Partial<PlatformIdentitiesPayload> = {}): PlatformIdentitiesPayload {
  return {
    platform_identities: [],
    available_platforms: [
      { platform: "telegram", label: "Telegram", configured: true },
      { platform: "slack", label: "Slack", configured: false }
    ],
    ...overrides
  }
}

function telegramIdentity(overrides: Partial<PlatformIdentity> = {}): PlatformIdentity {
  return {
    id: 42,
    platform: "telegram",
    external_handle: "@alice",
    linked_at: "2026-01-01T00:00:00Z",
    ...overrides
  }
}

function availablePlatform(overrides: Partial<AvailablePlatform> = {}): AvailablePlatform {
  return {
    platform: "telegram",
    label: "Telegram",
    configured: true,
    ...overrides
  }
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ConnectedPlatformsRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ConnectedPlatformsRoute", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.mocked(useConfirm).mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => {
    receivedHandler = undefined
    vi.restoreAllMocks()
  })

  it("shows linked accounts and disables unconfigured platforms", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(platformIdentitiesPayload({
      platform_identities: [
        telegramIdentity({ id: 7, external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" })
      ]
    })))

    renderRoute()

    expect(await screen.findByText("Connected Platforms")).toBeInTheDocument()
    expect(await screen.findByText(/Connected as @ada since/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Disconnect" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Not yet available" })).toBeDisabled()
  })

  it("requests a linking token and updates when ActionCable reports completion", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/platform_identities/linking_token" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({
          token: "signed-token",
          instructions: { text: "Send /start signed-token to @SyrusBot on Telegram", bot_handle: "SyrusBot" }
        }))
      }
      return Promise.resolve(jsonResponse(platformIdentitiesPayload()))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Connect" }))

    expect(await screen.findByText("How to connect")).toBeInTheDocument()
    expect(screen.getByText("Send /start signed-token to @SyrusBot on Telegram")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/platform_identities/linking_token",
      expect.objectContaining({ method: "POST" })
    )

    receivedHandler?.({
      type: "platform_identity_linked",
      payload: platformIdentitiesPayload({
        platform_identities: [
          telegramIdentity({ id: 8, external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" })
        ],
        available_platforms: [
          availablePlatform({ label: "Telegram" }),
          availablePlatform({ platform: "slack", label: "Slack", configured: false })
        ]
      })
    })

    await waitFor(() => {
      expect(screen.getByText(/Connected as @ada since/)).toBeInTheDocument()
    })
    expect(screen.getByText("Telegram account connected.")).toBeInTheDocument()
  })

  it("opens confirm dialog instead of window.confirm when disconnecting a platform", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(platformIdentitiesPayload({
      platform_identities: [ telegramIdentity() ]
    })))

    renderRoute()

    const disconnectButton = await screen.findByRole("button", { name: "Disconnect" })
    fireEvent.click(disconnectButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({
        destructive: true,
        message: "Disconnect your Telegram account?"
      }))
    })
  })

  it("calls the delete API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/platform_identities/42" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(platformIdentitiesPayload({ platform_identities: [], message: "Disconnected." })))
      }
      return Promise.resolve(jsonResponse(platformIdentitiesPayload({
        platform_identities: [ telegramIdentity() ]
      })))
    })
    renderRoute()

    const disconnectButton = await screen.findByRole("button", { name: "Disconnect" })
    fireEvent.click(disconnectButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/platform_identities/42",
        expect.objectContaining({ method: "DELETE" })
      )
    })
  })

  it("does not call the delete API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(platformIdentitiesPayload({
      platform_identities: [ telegramIdentity() ]
    })))
    renderRoute()

    const disconnectButton = await screen.findByRole("button", { name: "Disconnect" })
    await act(async () => { fireEvent.click(disconnectButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/platform_identities/42",
      expect.objectContaining({ method: "DELETE" })
    )
  })
})

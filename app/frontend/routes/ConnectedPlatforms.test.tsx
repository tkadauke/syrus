import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConnectedPlatformsRoute } from "./ConnectedPlatforms"
import * as useConfirmModule from "../hooks/useConfirm"

function mockUseConfirm(confirmed: boolean) {
  const mockConfirm = vi.fn<ReturnType<typeof useConfirmModule.useConfirm>["confirm"]>().mockResolvedValue(confirmed)
  vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm, dialog: <></> })
  return mockConfirm
}

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

function payload(overrides: Record<string, unknown> = {}) {
  return {
    platform_identities: [],
    available_platforms: [
      { platform: "telegram", configured: true },
      { platform: "slack", configured: false }
    ],
    ...overrides
  }
}

function renderRoute() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <ConnectedPlatformsRoute />
    </QueryClientProvider>
  )
}

describe("ConnectedPlatformsRoute", () => {
  afterEach(() => {
    receivedHandler = undefined
    vi.restoreAllMocks()
  })

  it("shows linked accounts and disables unconfigured platforms", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      platform_identities: [
        { id: 7, platform: "telegram", external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" }
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
      return Promise.resolve(jsonResponse(payload()))
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
      payload: payload({
        platform_identities: [
          { id: 8, platform: "telegram", external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" }
        ]
      })
    })

    await waitFor(() => {
      expect(screen.getByText(/Connected as @ada since/)).toBeInTheDocument()
    })
    expect(screen.getByText("Telegram account connected.")).toBeInTheDocument()
  })

  it("opens the shared confirm dialog before disconnecting a platform", async () => {
    const mockConfirm = mockUseConfirm(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/platform_identities/7" && init?.method === "DELETE") {
        return Promise.resolve(jsonResponse(payload({ message: "Disconnected." })))
      }
      return Promise.resolve(jsonResponse(payload({
        platform_identities: [
          { id: 7, platform: "telegram", external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" }
        ]
      })))
    })

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Disconnect" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true })))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/platform_identities/7", expect.objectContaining({ method: "DELETE" }))
    })
  })

  it("does not disconnect when the shared confirm dialog is cancelled", async () => {
    const mockConfirm = mockUseConfirm(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      platform_identities: [
        { id: 7, platform: "telegram", external_handle: "@ada", linked_at: "2026-08-02T12:00:00Z" }
      ]
    })))

    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Disconnect" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalled())
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/platform_identities/7", expect.anything())
  })
})

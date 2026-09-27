import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConnectionContext } from "../lib/connectionContext"
import { ConnectionStatusButton, ConnectionStatusRoute } from "./ConnectionStatus"

describe("ConnectionStatusButton", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("opens a compact desktop popover with current status and recent events", () => {
    mockDesktopViewport()

    render(
      <MemoryRouter>
        <ConnectionContext.Provider value={{
          events: [
            { id: 1, kind: "reconnecting", at: Date.now() },
            { id: 2, kind: "disconnected", at: Date.now() - 1000 }
          ],
          isDisconnected: true,
          reconnectAt: null,
          status: "reconnecting"
        }}>
          <ConnectionStatusButton prefix="" />
        </ConnectionContext.Provider>
      </MemoryRouter>
    )

    const button = screen.getByRole("button", { name: "Reconnecting" })
    fireEvent.click(button)

    const dialog = screen.getByText("Live updates are paused while Syrus reconnects. Chat views may use fallback polling.").closest("div")
    expect(dialog).not.toBeNull()
    expect(screen.getByRole("heading", { name: "Reconnecting" })).toBeInTheDocument()
    expect(screen.getByText("Recent events")).toBeInTheDocument()
    expect(screen.getAllByText("Reconnecting")).toHaveLength(2)
    expect(screen.getByText("Disconnected")).toBeInTheDocument()
  })

  it("links to the mobile connection status route", () => {
    mockMobileViewport()

    render(
      <MemoryRouter>
        <ConnectionContext.Provider value={{ events: [], isDisconnected: false, reconnectAt: null, status: "connected" }}>
          <ConnectionStatusButton prefix="/app-shell" />
        </ConnectionContext.Provider>
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "Live updates active" })).toHaveAttribute("href", "/app-shell/connection")
  })
})

describe("ConnectionStatusRoute", () => {
  it("renders the full-page mobile-style panel", () => {
    render(
      <ConnectionContext.Provider value={{
        events: [{ id: 1, kind: "connected", at: Date.now() }],
        isDisconnected: false,
        reconnectAt: Date.now(),
        status: "connected"
      }}>
        <MemoryRouter initialEntries={["/app-shell/connection"]}>
          <Routes>
            <Route element={<ConnectionStatusRoute />} path="/app-shell/connection" />
          </Routes>
        </MemoryRouter>
      </ConnectionContext.Provider>
    )

    const main = screen.getByRole("main", { name: "Live update status" })
    expect(within(main).getByRole("heading", { name: "Live updates active" })).toBeInTheDocument()
    expect(within(main).getByText("Syrus is receiving live updates over the websocket connection.")).toBeInTheDocument()
    expect(within(main).getByText("Connected")).toBeInTheDocument()
  })
})

function mockDesktopViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query !== "(max-width: 767px)",
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

function mockMobileViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches: query === "(max-width: 767px)",
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

import { describe, expect, it, vi } from "vitest"
import { AppUserCableClient, type AppUserCableSocket } from "../electron/appUserCable"

class FakeSocket implements AppUserCableSocket {
  readyState = 0
  send = vi.fn()
  close = vi.fn(() => {
    this.readyState = 3
    this.onclose?.()
  })
  onopen: ((event?: unknown) => unknown) | null = null
  onmessage: ((event: { data: unknown }) => void) | null = null
  onerror: ((event?: unknown) => unknown) | null = null
  onclose: ((event?: unknown) => unknown) | null = null

  open() { this.readyState = 1; this.onopen?.() }
  receive(message: object) { this.onmessage?.({ data: JSON.stringify(message) }) }
}

const credentials = { url: "https://syrus.example", token: "revocable" }

const setup = () => {
  const sockets: FakeSocket[] = []
  const delays: number[] = []
  const timers: Array<() => void> = []
  const unauthorized = vi.fn()
  const client = new AppUserCableClient({
    createSocket: () => { const socket = new FakeSocket(); sockets.push(socket); return socket },
    cableUrl: () => "wss://syrus.example/cable",
    credentialsKey: ({ url, token }) => `${url}\n${token}`,
    onMessage: vi.fn(),
    onUnauthorized: unauthorized,
    setTimeout: ((callback: () => void, delay: number) => {
      delays.push(delay)
      timers.push(callback)
      return timers.length
    }),
    clearTimeout: vi.fn()
  })
  return { client, sockets, delays, timers, unauthorized }
}

describe("AppUserCableClient", () => {
  it("keeps increasing backoff when opened sockets reject the subscription", () => {
    const { client, sockets, delays, timers } = setup()
    client.start(credentials)
    sockets[0].open()
    sockets[0].receive({ type: "welcome" })
    sockets[0].receive({ type: "reject_subscription" })
    timers.shift()?.()
    sockets[1].open()
    sockets[1].receive({ type: "welcome" })
    sockets[1].receive({ type: "reject_subscription" })
    expect(delays).toEqual([1_000, 2_000])
  })

  it("resets backoff after the subscription is confirmed", () => {
    const { client, sockets, delays, timers } = setup()
    client.start(credentials)
    sockets[0].onclose?.()
    timers.shift()?.()
    sockets[1].receive({ type: "confirm_subscription" })
    sockets[1].onclose?.()
    expect(delays).toEqual([1_000, 1_000])
  })

  it("marks unauthorized disconnects suspect and stops reconnecting", () => {
    const { client, sockets, delays, unauthorized } = setup()
    client.start(credentials)
    sockets[0].open()
    sockets[0].receive({ type: "disconnect", reason: "unauthorized" })
    expect(unauthorized).toHaveBeenCalledWith(credentials)
    expect(sockets[0].close).toHaveBeenCalledOnce()
    expect(delays).toEqual([])
  })
})

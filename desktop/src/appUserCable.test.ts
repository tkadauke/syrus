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
  const onMessage = vi.fn()
  const client = new AppUserCableClient({
    createSocket: () => { const socket = new FakeSocket(); sockets.push(socket); return socket },
    cableUrl: () => "wss://syrus.example/cable",
    credentialsKey: ({ url, token }) => `${url}\n${token}`,
    onMessage,
    onUnauthorized: unauthorized,
    setTimeout: ((callback: () => void, delay: number) => {
      delays.push(delay)
      timers.push(callback)
      return timers.length
    }),
    clearTimeout: vi.fn()
  })
  return { client, sockets, delays, timers, unauthorized, onMessage }
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

  // Every ActionCable frame with a "message" key was forwarded: the server's
  // pings ({type: "ping", message: <timestamp>}) every few seconds, frames for
  // a subscription that was never confirmed, and frames after a rejection.
  // Only this channel's broadcasts, on a confirmed subscription, are messages.
  it("delivers only this channel's broadcasts, and only once the subscription is confirmed", () => {
    const { client, sockets, onMessage } = setup()
    const identifier = JSON.stringify({ channel: "AppUserChannel" })
    client.start(credentials)
    sockets[0].open()
    sockets[0].receive({ type: "welcome" })
    sockets[0].receive({ type: "ping", message: 1_700_000_000 })
    sockets[0].receive({ identifier, message: { type: "notification_created", id: 1 } })
    sockets[0].receive({ type: "confirm_subscription", identifier })
    sockets[0].receive({ type: "ping", message: 1_700_000_003 })
    sockets[0].receive({ identifier: JSON.stringify({ channel: "OtherChannel" }), message: { id: 2 } })
    sockets[0].receive({ identifier, message: { type: "notification_created", id: 3 } })

    expect(onMessage.mock.calls).toEqual([[{ type: "notification_created", id: 3 }]])
  })

  // The cable has no replay: notifications broadcast while it was down are
  // never delivered, so the tray badge stayed stale until the popover opened
  // or another notification happened to arrive. Each confirmed subscription
  // (first connect and every reconnect) is the point to resync from the
  // authoritative count.
  it("reports every confirmed subscription so the unread count can resync", () => {
    const onSubscribed = vi.fn()
    const sockets: FakeSocket[] = []
    const timers: Array<() => void> = []
    const client = new AppUserCableClient({
      createSocket: () => { const socket = new FakeSocket(); sockets.push(socket); return socket },
      cableUrl: () => "wss://syrus.example/cable",
      credentialsKey: ({ url, token }) => `${url}\n${token}`,
      onMessage: vi.fn(),
      onUnauthorized: vi.fn(),
      onSubscribed,
      setTimeout: ((callback: () => void) => { timers.push(callback); return timers.length }),
      clearTimeout: vi.fn()
    })
    const identifier = JSON.stringify({ channel: "AppUserChannel" })
    client.start(credentials)
    sockets[0].open()
    sockets[0].receive({ type: "confirm_subscription", identifier })
    sockets[0].onclose?.()
    timers.shift()?.()
    sockets[1].open()
    sockets[1].receive({ type: "confirm_subscription", identifier })

    expect(onSubscribed).toHaveBeenCalledTimes(2)
  })

  it("delivers nothing on a socket whose subscription was rejected", () => {
    const { client, sockets, onMessage, timers } = setup()
    const identifier = JSON.stringify({ channel: "AppUserChannel" })
    client.start(credentials)
    sockets[0].open()
    sockets[0].receive({ type: "reject_subscription", identifier })
    sockets[0].receive({ identifier, message: { type: "notification_created", id: 1 } })
    timers.shift()?.()
    sockets[1].open()
    sockets[1].receive({ identifier, message: { type: "notification_created", id: 2 } })

    expect(onMessage).not.toHaveBeenCalled()
  })
})

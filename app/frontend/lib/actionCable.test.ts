import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { subscribeToAppEvents } from "./actionCable"

describe("subscribeToAppEvents", () => {
  it("subscribes to the app user channel and invalidates queries for received events", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const unsubscribe = vi.fn()
    let received: ((data: unknown) => void) | undefined
    const consumer = {
      subscriptions: {
        create: vi.fn((_params, mixin) => {
          received = mixin.received
          return { perform: vi.fn(), unsubscribe }
        })
      }
    }

    const subscription = subscribeToAppEvents(queryClient, consumer)

    expect(consumer.subscriptions.create).toHaveBeenCalledWith(
      { channel: "AppUserChannel" },
      expect.objectContaining({ received: expect.any(Function) })
    )

    received?.({
      type: "admin_overview.updated",
      resource: "admin_overview",
      id: null,
      changed: [],
      occurred_at: "2026-05-30T12:00:00.000Z"
    })

    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["admin", "overview"] })

    subscription.unsubscribe()
    expect(unsubscribe).toHaveBeenCalled()
  })

  it("invalidates all queries on reconnect but not initial connect", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    let connected: (() => void) | undefined
    const consumer = {
      subscriptions: {
        create: vi.fn((_params, mixin) => {
          connected = mixin.connected
          return { perform: vi.fn(), unsubscribe: vi.fn() }
        })
      }
    }

    subscribeToAppEvents(queryClient, consumer)

    expect(consumer.subscriptions.create).toHaveBeenCalledWith(
      { channel: "AppUserChannel" },
      expect.objectContaining({ connected: expect.any(Function) })
    )

    connected?.()
    expect(invalidate).not.toHaveBeenCalled()

    connected?.()
    expect(invalidate).toHaveBeenCalledTimes(1)
    expect(invalidate).toHaveBeenCalledWith()
  })

  it("calls onConnectionChange(false) on disconnect after first connect, not before", () => {
    const queryClient = new QueryClient()
    const onConnectionChange = vi.fn()
    let connected: (() => void) | undefined
    let disconnected: (() => void) | undefined
    const consumer = {
      subscriptions: {
        create: vi.fn((_params, mixin) => {
          connected = mixin.connected
          disconnected = mixin.disconnected
          return { perform: vi.fn(), unsubscribe: vi.fn() }
        })
      }
    }

    subscribeToAppEvents(queryClient, consumer, onConnectionChange)

    disconnected?.()
    expect(onConnectionChange).not.toHaveBeenCalled()

    connected?.()
    disconnected?.()
    expect(onConnectionChange).toHaveBeenCalledTimes(1)
    expect(onConnectionChange).toHaveBeenCalledWith(false)
  })

  it("calls onConnectionChange(true) on reconnect but not initial connect", () => {
    const queryClient = new QueryClient()
    const onConnectionChange = vi.fn()
    let connected: (() => void) | undefined
    const consumer = {
      subscriptions: {
        create: vi.fn((_params, mixin) => {
          connected = mixin.connected
          return { perform: vi.fn(), unsubscribe: vi.fn() }
        })
      }
    }

    subscribeToAppEvents(queryClient, consumer, onConnectionChange)

    connected?.()
    expect(onConnectionChange).not.toHaveBeenCalled()

    connected?.()
    expect(onConnectionChange).toHaveBeenCalledTimes(1)
    expect(onConnectionChange).toHaveBeenCalledWith(true)
  })
})

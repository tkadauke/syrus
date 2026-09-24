import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { subscribeToAppEvents, subscribeToChatResourceEvents, subscribeToJobResourceEvents } from "./actionCable"

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

  it("runs scoped continuity recovery on reconnect but not initial connect", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    const refetch = vi.spyOn(queryClient, "refetchQueries").mockResolvedValue(undefined as never)
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
    expect(refetch).not.toHaveBeenCalled()

    connected?.()
    expect(refetch).toHaveBeenCalledWith({ type: "active", predicate: expect.any(Function) })
    expect(invalidate).not.toHaveBeenCalledWith()
    expect(invalidate).not.toHaveBeenCalled()
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

  it("resets app-event sequence tracking on reconnect so a stale sequence doesn't also trigger gap recovery", () => {
    const queryClient = new QueryClient()
    const invalidate = vi.spyOn(queryClient, "invalidateQueries")
    let connected: (() => void) | undefined
    let received: ((data: unknown) => void) | undefined
    const consumer = {
      subscriptions: {
        create: vi.fn((_params, mixin) => {
          connected = mixin.connected
          received = mixin.received
          return { perform: vi.fn(), unsubscribe: vi.fn() }
        })
      }
    }

    subscribeToAppEvents(queryClient, consumer)
    connected?.() // initial connect

    received?.({ type: "workflow.updated", resource: "workflow", id: 7, sequence: 1, changed: [] })
    const routineCallCount = invalidate.mock.calls.length
    invalidate.mockClear()

    connected?.() // reconnect -- resets sequence tracking, runs its own continuity sweep
    invalidate.mockClear()

    // Without the reset, sequence 1 -> 40 would look like a huge gap on top
    // of the routine per-event invalidation; the reset means this is
    // treated as the first event of a fresh stream instead.
    received?.({ type: "workflow.updated", resource: "workflow", id: 7, sequence: 40, changed: [] })

    expect(invalidate).toHaveBeenCalledTimes(routineCallCount)
  })

  it("calls onSubscriptionChange on EVERY connect/disconnect, including the very first connect", () => {
    // Unlike onConnectionChange (reconnect-only, drives the "reconnected"
    // banner), the desktop-shell notification-liveness signal needs "are we
    // subscribed right now" from the start, not just recovery from a drop.
    const queryClient = new QueryClient()
    const onSubscriptionChange = vi.fn()
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

    subscribeToAppEvents(queryClient, consumer, undefined, onSubscriptionChange)

    connected?.()
    expect(onSubscriptionChange).toHaveBeenNthCalledWith(1, true)

    disconnected?.()
    expect(onSubscriptionChange).toHaveBeenNthCalledWith(2, false)

    connected?.()
    expect(onSubscriptionChange).toHaveBeenNthCalledWith(3, true)
    expect(onSubscriptionChange).toHaveBeenCalledTimes(3)
  })
})

describe("subscribeToJobResourceEvents", () => {
  it("subscribes to JobChannel scoped to the given job id and applies received events", () => {
    const queryClient = new QueryClient()
    const setQueryData = vi.spyOn(queryClient, "setQueryData")
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

    const subscription = subscribeToJobResourceEvents(42, queryClient, consumer)

    expect(consumer.subscriptions.create).toHaveBeenCalledWith(
      { channel: "JobChannel", job_id: 42 },
      expect.objectContaining({ received: expect.any(Function) })
    )

    received?.({
      type: "workflow.updated",
      resource: "workflow",
      id: 7,
      changed: [ "state" ],
      occurred_at: "2026-05-30T12:00:00.000Z",
      payload: { fields: { state: "running" } }
    })

    // No "sequence" on the event -- entity store patches happen directly,
    // no notifications cache to touch for a workflow resource.
    expect(setQueryData).not.toHaveBeenCalled()

    subscription.unsubscribe()
    expect(unsubscribe).toHaveBeenCalled()
  })

  it("runs a bounded, job-scoped refetch on reconnect but not initial connect", () => {
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

    subscribeToJobResourceEvents(42, queryClient, consumer)

    connected?.() // initial connect
    expect(invalidate).not.toHaveBeenCalled()

    connected?.() // reconnect
    expect(invalidate).toHaveBeenCalledWith({ queryKey: [ "jobs", "42", "detail" ] })
    expect(invalidate).toHaveBeenCalledWith({ queryKey: [ "jobs", "42", "workflows" ] })
  })
})

describe("subscribeToChatResourceEvents", () => {
  it("subscribes to ChatChannel scoped to the given chat id and applies received events", () => {
    const queryClient = new QueryClient()
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

    const subscription = subscribeToChatResourceEvents(7, queryClient, consumer)

    expect(consumer.subscriptions.create).toHaveBeenCalledWith(
      { channel: "ChatChannel", chat_id: 7 },
      expect.objectContaining({ received: expect.any(Function) })
    )

    expect(() => received?.({
      type: "updated",
      resource: "chat",
      id: 7,
      changed: [ "messages" ],
      occurred_at: "2026-05-30T12:00:00.000Z",
      payload: { action: "invalidate_messages", turn_in_flight: false }
    })).not.toThrow()

    subscription.unsubscribe()
    expect(unsubscribe).toHaveBeenCalled()
  })

  it("runs a bounded, chat-scoped refetch on reconnect but not initial connect", () => {
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

    subscribeToChatResourceEvents(7, queryClient, consumer)

    connected?.() // initial connect
    expect(invalidate).not.toHaveBeenCalled()

    connected?.() // reconnect
    expect(invalidate).toHaveBeenCalledWith({ queryKey: [ "chats", "7" ] })
  })
})

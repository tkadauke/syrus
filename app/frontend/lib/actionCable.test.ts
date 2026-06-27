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
})

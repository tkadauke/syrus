import { createConsumer, type Consumer, type Subscription } from "@rails/actioncable"
import type { QueryClient } from "@tanstack/react-query"
import { applyAppEvent, type AppEvent } from "./appEvents"

export function subscribeToAppEvents(
  queryClient: QueryClient,
  consumer: Consumer = createConsumer(),
  onConnectionChange?: (connected: boolean) => void,
  // Unlike onConnectionChange (reconnect-only, drives the "reconnected"
  // banner), this fires on EVERY connect/disconnect including the very
  // first one — the desktop shell's native-notification liveness signal
  // (nativeNotifications.ts) needs to know "are we subscribed right now,"
  // not "did we just recover from a drop."
  onSubscriptionChange?: (subscribed: boolean) => void
): Subscription {
  let everConnected = false

  return consumer.subscriptions.create(
    { channel: "AppUserChannel" },
    {
      connected() {
        const wasConnected = everConnected
        if (wasConnected) {
          void queryClient.invalidateQueries()
          onConnectionChange?.(true)
        }
        everConnected = true
        onSubscriptionChange?.(true)
      },
      disconnected() {
        if (everConnected) {
          onConnectionChange?.(false)
        }
        onSubscriptionChange?.(false)
      },
      received(data: unknown) {
        applyAppEvent(queryClient, data as AppEvent)
      }
    }
  )
}

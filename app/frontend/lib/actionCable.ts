import { createConsumer, type Consumer, type Subscription } from "@rails/actioncable"
import type { QueryClient } from "@tanstack/react-query"
import { applyAppEvent, recoverAppEventContinuity, type AppEvent } from "./appEvents"

let sharedConsumer: Consumer | null = null

// Every ActionCable subscriber in the app should share this single
// Consumer (one underlying WebSocket, multiplexing every channel
// subscription) instead of calling createConsumer() itself. A component
// that creates its own Consumer and only ever calls
// subscription.unsubscribe() on cleanup leaks an open WebSocket forever —
// unsubscribe drops the channel subscription but never closes the socket.
export function getAppConsumer(): Consumer {
  if (!sharedConsumer) sharedConsumer = createConsumer()
  return sharedConsumer
}

export function subscribeToAppEvents(
  queryClient: QueryClient,
  consumer: Consumer = getAppConsumer(),
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
          recoverAppEventContinuity(queryClient)
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

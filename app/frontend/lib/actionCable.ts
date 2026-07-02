import { createConsumer, type Consumer, type Subscription } from "@rails/actioncable"
import type { QueryClient } from "@tanstack/react-query"
import { applyAppEvent, type AppEvent } from "./appEvents"

export function subscribeToAppEvents(
  queryClient: QueryClient,
  consumer: Consumer = createConsumer(),
  onConnectionChange?: (connected: boolean) => void
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
      },
      disconnected() {
        if (everConnected) {
          onConnectionChange?.(false)
        }
      },
      received(data: unknown) {
        applyAppEvent(queryClient, data as AppEvent)
      }
    }
  )
}

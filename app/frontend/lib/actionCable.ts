import { createConsumer, type Consumer, type Subscription } from "@rails/actioncable"
import type { QueryClient } from "@tanstack/react-query"
import { applyAppEvent, type AppEvent } from "./appEvents"

export function subscribeToAppEvents(
  queryClient: QueryClient,
  consumer: Consumer = createConsumer()
): Subscription {
  let everConnected = false

  return consumer.subscriptions.create(
    { channel: "AppUserChannel" },
    {
      connected() {
        if (everConnected) {
          void queryClient.invalidateQueries()
        }
        everConnected = true
      },
      received(data: unknown) {
        applyAppEvent(queryClient, data as AppEvent)
      }
    }
  )
}

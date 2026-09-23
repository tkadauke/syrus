import { createConsumer, type Consumer, type Subscription } from "@rails/actioncable"
import type { QueryClient } from "@tanstack/react-query"
import { applyAppEvent, recoverAppEventContinuity, recoverChatResourceContinuity, recoverJobResourceContinuity, resetAppEventSequenceTracking, type AppEvent } from "./appEvents"

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
          // A reconnect already means events were missed during the drop,
          // and recoverAppEventContinuity's sweep below covers exactly
          // that window -- broader than the single-resource recovery a
          // stale sequence would otherwise also trigger on the first
          // post-reconnect event. Reset so that per-event gap detection
          // only fires for genuine mid-connection drops going forward.
          resetAppEventSequenceTracking(queryClient)
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

// Resource-scoped subscriptions for an actively-viewed Job or Chat, over the
// same shared multiplexed consumer as AppUserChannel above -- one WebSocket
// per tab either way. Callers subscribe on mount/id-change and unsubscribe on
// cleanup (see JobDetailRoute/ChatRoute), so a route change or closed panel
// releases the stream and stops receiving that resource's detailed events.
// Every received event is routed through the same applyAppEvent used for the
// global channel; resource-scoped events simply arrive without a `sequence`,
// so they apply directly rather than participating in gap detection (see
// AppEvents.broadcast_job_resource/broadcast_chat_resource for why that's
// safe). A reconnect on one of these subscriptions can only have missed
// events about that one resource, so recovery is a single bounded refetch
// instead of the app-wide continuity sweep a global reconnect triggers.
export function subscribeToJobResourceEvents(
  jobId: string | number,
  queryClient: QueryClient,
  consumer: Consumer = getAppConsumer()
): Subscription {
  let everConnected = false

  return consumer.subscriptions.create(
    { channel: "JobChannel", job_id: jobId },
    {
      connected() {
        if (everConnected) recoverJobResourceContinuity(queryClient, jobId)
        everConnected = true
      },
      received(data: unknown) {
        applyAppEvent(queryClient, data as AppEvent)
      }
    }
  )
}

export function subscribeToChatResourceEvents(
  chatId: string | number,
  queryClient: QueryClient,
  consumer: Consumer = getAppConsumer()
): Subscription {
  let everConnected = false

  return consumer.subscriptions.create(
    { channel: "ChatChannel", chat_id: chatId },
    {
      connected() {
        if (everConnected) recoverChatResourceContinuity(queryClient, chatId)
        everConnected = true
      },
      received(data: unknown) {
        applyAppEvent(queryClient, data as AppEvent)
      }
    }
  )
}

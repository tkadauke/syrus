import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { renderHook } from "@testing-library/react"
import type { ReactNode } from "react"
import { describe, expect, it, vi } from "vitest"
import { useAppEvents } from "./useAppEvents"

const { subscribeToAppEvents, unsubscribe, setNativeNotificationCableSubscribed } = vi.hoisted(() => {
  const unsubscribe = vi.fn()
  return {
    unsubscribe,
    subscribeToAppEvents: vi.fn((
      _queryClient?: unknown,
      _consumer?: unknown,
      _onConnectionChange?: unknown,
      _onSubscriptionChange?: unknown
    ) => ({ unsubscribe })),
    setNativeNotificationCableSubscribed: vi.fn()
  }
})

vi.mock("./actionCable", () => ({ subscribeToAppEvents }))
vi.mock("./nativeNotifications", () => ({ setNativeNotificationCableSubscribed }))

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient()
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
}

describe("useAppEvents", () => {
  it("subscribes with a 4th argument that forwards into the notification-liveness reporter", () => {
    renderHook(() => useAppEvents(), { wrapper })

    expect(subscribeToAppEvents).toHaveBeenCalledWith(expect.anything(), undefined, expect.any(Function), expect.any(Function))

    const onSubscriptionChange = subscribeToAppEvents.mock.calls[0][3] as (subscribed: boolean) => void
    onSubscriptionChange(true)
    expect(setNativeNotificationCableSubscribed).toHaveBeenCalledWith(true)
  })

  it("reports the cable no-longer-subscribed on unmount, alongside unsubscribing", () => {
    const { unmount } = renderHook(() => useAppEvents(), { wrapper })
    setNativeNotificationCableSubscribed.mockClear()

    unmount()

    expect(unsubscribe).toHaveBeenCalledOnce()
    expect(setNativeNotificationCableSubscribed).toHaveBeenCalledWith(false)
  })
})

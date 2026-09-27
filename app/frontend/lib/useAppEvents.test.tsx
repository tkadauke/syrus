import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, renderHook } from "@testing-library/react"
import type { ReactNode } from "react"
import { beforeEach, describe, expect, it, vi } from "vitest"
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
  beforeEach(() => {
    vi.useRealTimers()
    subscribeToAppEvents.mockClear()
    unsubscribe.mockClear()
    setNativeNotificationCableSubscribed.mockClear()
  })

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

  it("keeps transient disconnects ambient during the grace window", () => {
    vi.useFakeTimers()
    const { result } = renderHook(() => useAppEvents(), { wrapper })
    const onConnectionChange = subscribeToAppEvents.mock.calls[0][2] as (connected: boolean) => void

    act(() => onConnectionChange(false))

    expect(result.current.isDisconnected).toBe(true)
    expect(result.current.status).toBe("connected")
    expect(result.current.events[0].kind).toBe("disconnected")

    act(() => {
      vi.advanceTimersByTime(3999)
      onConnectionChange(true)
    })

    expect(result.current.status).toBe("connected")
    expect(result.current.justReconnected).toBe(false)
    expect(result.current.events[0].kind).toBe("connected")
  })

  it("surfaces reconnecting after the grace window and only then reports reconnected", () => {
    vi.useFakeTimers()
    const { result } = renderHook(() => useAppEvents(), { wrapper })
    const onConnectionChange = subscribeToAppEvents.mock.calls[0][2] as (connected: boolean) => void

    act(() => onConnectionChange(false))
    act(() => vi.advanceTimersByTime(4000))

    expect(result.current.status).toBe("reconnecting")
    expect(result.current.events[0].kind).toBe("reconnecting")

    act(() => onConnectionChange(true))

    expect(result.current.status).toBe("connected")
    expect(result.current.justReconnected).toBe(true)
    expect(result.current.events[0].kind).toBe("reconnected")
  })
})

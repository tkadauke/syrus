import { act, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { NoticeToast } from "./NoticeToast"

describe("NoticeToast", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("dismisses itself after ten seconds", () => {
    vi.useFakeTimers()
    const onDismiss = vi.fn()
    render(<NoticeToast message="Bug report queued." onDismiss={onDismiss} />)

    expect(screen.getByRole("status")).toHaveTextContent("Bug report queued.")

    act(() => {
      vi.advanceTimersByTime(9_999)
    })
    expect(onDismiss).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })

  it("still supports manual dismissal", () => {
    const onDismiss = vi.fn()
    render(<NoticeToast message="Bug report queued." onDismiss={onDismiss} />)

    fireEvent.click(screen.getByRole("button", { name: "Dismiss notification" }))

    expect(onDismiss).toHaveBeenCalledTimes(1)
  })

  it("does not auto-dismiss when persistent", () => {
    vi.useFakeTimers()
    const onDismiss = vi.fn()
    render(<NoticeToast persistent message="Connection lost — updates paused" onDismiss={onDismiss} />)

    expect(screen.getByRole("status")).toHaveTextContent("Connection lost — updates paused")

    act(() => {
      vi.advanceTimersByTime(60_000)
    })
    expect(onDismiss).not.toHaveBeenCalled()
  })

  it("still allows manual dismissal when persistent", () => {
    const onDismiss = vi.fn()
    render(<NoticeToast persistent message="Connection lost — updates paused" onDismiss={onDismiss} />)

    fireEvent.click(screen.getByRole("button", { name: "Dismiss notification" }))

    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})

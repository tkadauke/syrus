import { act, fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { NoticeToast } from "./NoticeToast"
import { NOTICE_AUTO_DISMISS_DELAY_MS } from "./noticeStyles"

describe("NoticeToast", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("dismisses itself after the shared notice delay", () => {
    vi.useFakeTimers()
    const onDismiss = vi.fn()
    render(<NoticeToast message="Bug report queued." onDismiss={onDismiss} />)

    expect(screen.getByRole("status")).toHaveTextContent("Bug report queued.")

    act(() => {
      vi.advanceTimersByTime(NOTICE_AUTO_DISMISS_DELAY_MS - 1)
    })
    expect(onDismiss).not.toHaveBeenCalled()

    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })

  it("clears the mobile in-flow header while sitting near the top on desktop", () => {
    const onDismiss = vi.fn()
    render(<NoticeToast message="Bug report queued." onDismiss={onDismiss} />)

    const classes = screen.getByRole("status").className
    expect(classes).toContain("top-[68px]")
    expect(classes).toContain("lg:top-4")
  })

  it("uses the shared notice surface animation", () => {
    const onDismiss = vi.fn()
    render(<NoticeToast message="Bug report queued." onDismiss={onDismiss} />)

    expect(screen.getByRole("status").firstElementChild).toHaveClass("motion-safe:animate-notice-in")
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

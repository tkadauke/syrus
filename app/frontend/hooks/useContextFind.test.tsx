import { render } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { useContextFindShortcut } from "./useContextFind"

function ShortcutProbe({ enabled = true, onOpen }: { enabled?: boolean; onOpen: () => boolean | void }) {
  useContextFindShortcut({ enabled, onOpen })
  return <input aria-label="Editable" />
}

describe("useContextFindShortcut", () => {
  it("intercepts Cmd-F outside editable controls when a provider handles it", () => {
    const onOpen = vi.fn(() => true)
    render(<ShortcutProbe onOpen={onOpen} />)

    const event = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "f", metaKey: true })
    window.dispatchEvent(event)

    expect(onOpen).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
  })

  it("leaves browser find alone when the provider declines", () => {
    const onOpen = vi.fn(() => false)
    render(<ShortcutProbe onOpen={onOpen} />)

    const event = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "f", ctrlKey: true })
    window.dispatchEvent(event)

    expect(onOpen).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(false)
  })

  it("does not intercept inside editable controls", () => {
    const onOpen = vi.fn()
    render(<ShortcutProbe onOpen={onOpen} />)

    const input = document.querySelector("input")!
    input.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "f", metaKey: true }))

    expect(onOpen).not.toHaveBeenCalled()
  })
})

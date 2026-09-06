import { fireEvent, render, screen } from "@testing-library/react"
import { useRef } from "react"
import { describe, expect, it, vi } from "vitest"
import { useDismissiblePopup } from "./useDismissiblePopup"

function PopupHarness({ open, onClose }: { open: boolean; onClose: () => void }) {
  const ref = useDismissiblePopup<HTMLDivElement>(open, onClose)

  return (
    <>
      <button type="button">Outside</button>
      {open && (
        <div ref={ref} role="menu">
          <button type="button">Inside</button>
        </div>
      )}
    </>
  )
}

// Mimics a floating-ui FloatingPortal panel: rendered elsewhere in the DOM,
// not nested under the popup's own ref, but still logically "inside" it.
function PortaledPopupHarness({ open, onClose }: { open: boolean; onClose: () => void }) {
  const extraRef = useRef<HTMLDivElement | null>(null)
  const ref = useDismissiblePopup<HTMLDivElement>(open, onClose, extraRef)

  return (
    <>
      <button type="button">Outside</button>
      {open && <div ref={ref} role="menu" />}
      {open && (
        <div data-testid="portaled-panel" ref={extraRef}>
          <button type="button">Portaled inside</button>
        </div>
      )}
    </>
  )
}

describe("useDismissiblePopup", () => {
  it("closes an open popup with Escape", () => {
    const onClose = vi.fn()
    render(<PopupHarness open={true} onClose={onClose} />)

    fireEvent.keyDown(window, { key: "Escape" })

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it("closes an open popup when pointer input lands outside it", () => {
    const onClose = vi.fn()
    render(<PopupHarness open={true} onClose={onClose} />)

    fireEvent.pointerDown(screen.getByRole("button", { name: "Outside" }))

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it("keeps an open popup when pointer input stays inside it", () => {
    const onClose = vi.fn()
    render(<PopupHarness open={true} onClose={onClose} />)

    fireEvent.pointerDown(screen.getByRole("button", { name: "Inside" }))

    expect(onClose).not.toHaveBeenCalled()
  })

  it("does not install dismissal behavior while closed", () => {
    const onClose = vi.fn()
    render(<PopupHarness open={false} onClose={onClose} />)

    fireEvent.keyDown(window, { key: "Escape" })
    fireEvent.pointerDown(screen.getByRole("button", { name: "Outside" }))

    expect(onClose).not.toHaveBeenCalled()
  })

  it("keeps an open popup when pointer input lands inside a separately-provided extraRef (e.g. portaled content)", () => {
    const onClose = vi.fn()
    render(<PortaledPopupHarness open={true} onClose={onClose} />)

    fireEvent.pointerDown(screen.getByRole("button", { name: "Portaled inside" }))

    expect(onClose).not.toHaveBeenCalled()
  })

  it("still closes when pointer input lands outside both the ref and extraRef", () => {
    const onClose = vi.fn()
    render(<PortaledPopupHarness open={true} onClose={onClose} />)

    fireEvent.pointerDown(screen.getByRole("button", { name: "Outside" }))

    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

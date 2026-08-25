import { useRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Modal } from "./Modal"

describe("Modal", () => {
  it("renders nothing when closed", () => {
    render(
      <Modal label="Example" onClose={vi.fn()} open={false}>
        <p>Content</p>
      </Modal>
    )
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("renders the dialog with its content when open", () => {
    render(
      <Modal label="Example" onClose={vi.fn()} open>
        <p>Content</p>
      </Modal>
    )
    const dialog = screen.getByRole("dialog", { name: "Example" })
    expect(dialog).toBeInTheDocument()
    expect(dialog).toHaveAttribute("aria-modal", "true")
    expect(screen.getByText("Content")).toBeInTheDocument()
  })

  it("prefers aria-labelledby over label when both are given", () => {
    render(
      <Modal label="Fallback" labelledBy="heading" onClose={vi.fn()} open>
        <h2 id="heading">Real title</h2>
      </Modal>
    )
    expect(screen.getByRole("dialog", { name: "Real title" })).toBeInTheDocument()
  })

  it("calls onClose on Escape by default", () => {
    const onClose = vi.fn()
    render(
      <Modal label="Example" onClose={onClose} open>
        <p>Content</p>
      </Modal>
    )
    fireEvent.keyDown(document, { key: "Escape" })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it("does not call onClose on Escape when closeOnEscape is false", () => {
    const onClose = vi.fn()
    render(
      <Modal closeOnEscape={false} label="Example" onClose={onClose} open>
        <p>Content</p>
      </Modal>
    )
    fireEvent.keyDown(document, { key: "Escape" })
    expect(onClose).not.toHaveBeenCalled()
  })

  it("calls onClose when the backdrop is clicked", () => {
    const onClose = vi.fn()
    render(
      <Modal label="Example" onClose={onClose} open>
        <p>Content</p>
      </Modal>
    )
    fireEvent.click(screen.getByRole("presentation"))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it("does not call onClose when clicking inside the panel", () => {
    const onClose = vi.fn()
    render(
      <Modal label="Example" onClose={onClose} open>
        <p>Content</p>
      </Modal>
    )
    fireEvent.click(screen.getByRole("dialog"))
    expect(onClose).not.toHaveBeenCalled()
  })

  it("does not call onClose on backdrop click when closeOnBackdropClick is false", () => {
    const onClose = vi.fn()
    render(
      <Modal closeOnBackdropClick={false} label="Example" onClose={onClose} open>
        <p>Content</p>
      </Modal>
    )
    fireEvent.click(screen.getByRole("presentation"))
    expect(onClose).not.toHaveBeenCalled()
  })

  it("moves focus into the panel when opened", () => {
    render(
      <Modal label="Example" onClose={vi.fn()} open>
        <button type="button">First</button>
        <button type="button">Second</button>
      </Modal>
    )
    expect(screen.getByRole("button", { name: "First" })).toHaveFocus()
  })

  it("honors an explicit initialFocusRef", () => {
    function Fixture() {
      const secondRef = useRef<HTMLButtonElement>(null)
      return (
        <Modal initialFocusRef={secondRef} label="Example" onClose={vi.fn()} open>
          <button type="button">First</button>
          <button ref={secondRef} type="button">Second</button>
        </Modal>
      )
    }
    render(<Fixture />)
    expect(screen.getByRole("button", { name: "Second" })).toHaveFocus()
  })

  it("traps Tab within the panel, wrapping from the last to the first focusable element", () => {
    render(
      <Modal label="Example" onClose={vi.fn()} open>
        <button type="button">First</button>
        <button type="button">Second</button>
      </Modal>
    )
    screen.getByRole("button", { name: "Second" }).focus()
    fireEvent.keyDown(document, { key: "Tab" })
    expect(screen.getByRole("button", { name: "First" })).toHaveFocus()
  })

  it("traps Shift+Tab within the panel, wrapping from the first to the last focusable element", () => {
    render(
      <Modal label="Example" onClose={vi.fn()} open>
        <button type="button">First</button>
        <button type="button">Second</button>
      </Modal>
    )
    screen.getByRole("button", { name: "First" }).focus()
    fireEvent.keyDown(document, { key: "Tab", shiftKey: true })
    expect(screen.getByRole("button", { name: "Second" })).toHaveFocus()
  })

  it("restores focus to the previously focused element on close", () => {
    const onClose = vi.fn()
    const { rerender } = render(
      <>
        <button type="button">Trigger</button>
        <Modal label="Example" onClose={onClose} open={false}>
          <button type="button">Inside</button>
        </Modal>
      </>
    )

    const trigger = screen.getByRole("button", { name: "Trigger" })
    trigger.focus()
    expect(trigger).toHaveFocus()

    rerender(
      <>
        <button type="button">Trigger</button>
        <Modal label="Example" onClose={onClose} open>
          <button type="button">Inside</button>
        </Modal>
      </>
    )
    expect(screen.getByRole("button", { name: "Inside" })).toHaveFocus()

    rerender(
      <>
        <button type="button">Trigger</button>
        <Modal label="Example" onClose={onClose} open={false}>
          <button type="button">Inside</button>
        </Modal>
      </>
    )
    expect(trigger).toHaveFocus()
  })
})

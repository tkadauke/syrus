import { fireEvent, render, screen } from "@testing-library/react"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"
import { ShortcutsProvider, useActiveShortcuts, useShortcut } from "./ShortcutsContext"

function Registrant({ keys, label, onFire, group = "Test" }: { keys: string; label: string; onFire: () => void; group?: string }) {
  useShortcut(keys, onFire, { description: `${label} description`, group })
  return <div>{label} mounted</div>
}

function Toggleable({ children }: { children: React.ReactNode }) {
  const [mounted, setMounted] = useState(true)
  return (
    <div>
      <button onClick={() => setMounted(false)} type="button">unmount</button>
      {mounted ? children : null}
    </div>
  )
}

function ActiveShortcutsProbe() {
  const shortcuts = useActiveShortcuts()
  return (
    <ul>
      {shortcuts.map((shortcut) => (
        <li key={shortcut.keys}>{shortcut.group}: {shortcut.description} ({shortcut.keys})</li>
      ))}
    </ul>
  )
}

describe("useShortcut / ShortcutsProvider", () => {
  it("dispatches to the registered handler when the combo is pressed", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Registrant keys="g" label="Go" onFire={onFire} />
      </ShortcutsProvider>
    )

    fireEvent.keyDown(window, { key: "g" })

    expect(onFire).toHaveBeenCalledTimes(1)
  })

  it("does not dispatch to an unregistered (unmounted) handler", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Toggleable>
          <Registrant keys="g" label="Go" onFire={onFire} />
        </Toggleable>
      </ShortcutsProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "unmount" }))
    fireEvent.keyDown(window, { key: "g" })

    expect(onFire).not.toHaveBeenCalled()
  })

  it("shadows an earlier registration LIFO by mount order, and restores it on unmount", () => {
    const pageHandler = vi.fn()
    const modalHandler = vi.fn()

    function Harness() {
      const [modalMounted, setModalMounted] = useState(false)
      return (
        <div>
          <button onClick={() => setModalMounted(true)} type="button">open modal</button>
          <button onClick={() => setModalMounted(false)} type="button">close modal</button>
          <Registrant keys="mod+k" label="Page" onFire={pageHandler} />
          {modalMounted ? <Registrant keys="mod+k" label="Modal" onFire={modalHandler} /> : null}
        </div>
      )
    }

    render(
      <ShortcutsProvider>
        <Harness />
      </ShortcutsProvider>
    )

    fireEvent.keyDown(window, { key: "k", ctrlKey: true })
    expect(pageHandler).toHaveBeenCalledTimes(1)
    expect(modalHandler).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "open modal" }))
    fireEvent.keyDown(window, { key: "k", ctrlKey: true })
    expect(pageHandler).toHaveBeenCalledTimes(1)
    expect(modalHandler).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole("button", { name: "close modal" }))
    fireEvent.keyDown(window, { key: "k", ctrlKey: true })
    expect(pageHandler).toHaveBeenCalledTimes(2)
    expect(modalHandler).toHaveBeenCalledTimes(1)
  })

  it("never fires while the keydown target is typing (input, textarea, contentEditable)", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Registrant keys="g" label="Go" onFire={onFire} />
        <input aria-label="plain-input" />
        <textarea aria-label="plain-textarea" />
        <div aria-label="editable" contentEditable suppressContentEditableWarning />
      </ShortcutsProvider>
    )

    fireEvent.keyDown(screen.getByLabelText("plain-input"), { key: "g" })
    fireEvent.keyDown(screen.getByLabelText("plain-textarea"), { key: "g" })
    fireEvent.keyDown(screen.getByLabelText("editable"), { key: "g" })

    expect(onFire).not.toHaveBeenCalled()
  })

  it("matches a bare symbol combo like '?' regardless of the shift flag the browser reports", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Registrant keys="?" label="Help" onFire={onFire} />
      </ShortcutsProvider>
    )

    fireEvent.keyDown(window, { key: "?", shiftKey: true })

    expect(onFire).toHaveBeenCalledTimes(1)
  })

  it("does not match a plain letter combo when a modifier is held", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Registrant keys="g" label="Go" onFire={onFire} />
      </ShortcutsProvider>
    )

    fireEvent.keyDown(window, { key: "g", ctrlKey: true })

    expect(onFire).not.toHaveBeenCalled()
  })

  it("exposes only the active (unshadowed, mounted) registrations from useActiveShortcuts", () => {
    function Harness() {
      const [modalMounted, setModalMounted] = useState(false)
      return (
        <div>
          <button onClick={() => setModalMounted(true)} type="button">open modal</button>
          <Registrant group="Global" keys="?" label="Help" onFire={() => {}} />
          <Registrant group="Page" keys="mod+k" label="Page action" onFire={() => {}} />
          {modalMounted ? <Registrant group="Modal" keys="mod+k" label="Modal action" onFire={() => {}} /> : null}
          <ActiveShortcutsProbe />
        </div>
      )
    }

    render(
      <ShortcutsProvider>
        <Harness />
      </ShortcutsProvider>
    )

    expect(screen.getByText("Global: Help description (?)")).toBeInTheDocument()
    expect(screen.getByText("Page: Page action description (mod+k)")).toBeInTheDocument()
    expect(screen.queryByText(/Modal action/)).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "open modal" }))

    expect(screen.queryByText("Page: Page action description (mod+k)")).not.toBeInTheDocument()
    expect(screen.getByText("Modal: Modal action description (mod+k)")).toBeInTheDocument()
  })

  it("throws when useShortcut is used outside a ShortcutsProvider", () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})

    expect(() => render(<Registrant keys="g" label="Go" onFire={() => {}} />)).toThrow(
      "useShortcut must be used within a ShortcutsProvider"
    )

    consoleError.mockRestore()
  })
})

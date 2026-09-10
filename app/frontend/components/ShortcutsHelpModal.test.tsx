import { fireEvent, render, screen, within } from "@testing-library/react"
import { useState } from "react"
import { describe, expect, it, vi } from "vitest"
import { ShortcutsProvider, useShortcut } from "../contexts/ShortcutsContext"
import { formatShortcutCombo, groupActiveShortcuts, ShortcutsHelpModal } from "./ShortcutsHelpModal"

function Registrant({ keys, label, group, groupOrder, onFire = () => {} }: { keys: string; label: string; group: string; groupOrder?: number; onFire?: () => void }) {
  useShortcut(keys, onFire, { description: label, group, groupOrder })
  return null
}

describe("groupActiveShortcuts", () => {
  it("groups by label and orders groups by the lowest groupOrder, alphabetically on ties", () => {
    const grouped = groupActiveShortcuts([
      { keys: "a", description: "A", group: "Zeta", groupOrder: 5 },
      { keys: "b", description: "B", group: "Alpha", groupOrder: 5 },
      { keys: "c", description: "C", group: "Global", groupOrder: 0 }
    ])

    expect(grouped.map((g) => g.group)).toEqual(["Global", "Alpha", "Zeta"])
  })

  it("keeps every item registered under the same group together", () => {
    const grouped = groupActiveShortcuts([
      { keys: "a", description: "A", group: "Job Detail", groupOrder: 1 },
      { keys: "b", description: "B", group: "Job Detail", groupOrder: 1 }
    ])

    expect(grouped).toHaveLength(1)
    expect(grouped[0].items.map((item) => item.keys)).toEqual(["a", "b"])
  })
})

describe("formatShortcutCombo", () => {
  it("leaves a bare symbol untouched", () => {
    expect(formatShortcutCombo("?")).toBe("?")
  })

  it("title-cases modifier and key tokens", () => {
    expect(formatShortcutCombo("mod+enter")).toBe("Mod + Enter")
  })

  it("labels Alt as Option on Apple platforms", () => {
    expect(formatShortcutCombo("alt+a", "MacIntel")).toBe("⌥ + A")
    expect(formatShortcutCombo("alt+a", "Win32")).toBe("Alt + A")
  })
})

describe("ShortcutsHelpModal", () => {
  it("renders nothing when closed", () => {
    render(
      <ShortcutsProvider>
        <ShortcutsHelpModal onClose={() => {}} open={false} />
      </ShortcutsProvider>
    )

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("renders a live snapshot grouped by each registration's group", () => {
    render(
      <ShortcutsProvider>
        <Registrant group="Global" groupOrder={0} keys="?" label="Show shortcuts" />
        <Registrant group="Job Detail" groupOrder={1} keys="alt+a" label="Approve" />
        <Registrant group="Job Detail" groupOrder={1} keys="alt+r" label="Retry" />
        <ShortcutsHelpModal onClose={() => {}} open />
      </ShortcutsProvider>
    )

    const dialog = screen.getByRole("dialog")
    expect(within(dialog).getByText("Global")).toBeInTheDocument()
    expect(within(dialog).getByText("Job Detail")).toBeInTheDocument()
    expect(within(dialog).getByText("Show shortcuts")).toBeInTheDocument()
    expect(within(dialog).getByText("Approve")).toBeInTheDocument()
    expect(within(dialog).getByText("Retry")).toBeInTheDocument()
    expect(within(dialog).getByText("?")).toBeInTheDocument()
  })

  it("never lists a shortcut that is unmounted or currently shadowed", () => {
    function Harness() {
      const [pageMounted, setPageMounted] = useState(true)
      const [modalMounted, setModalMounted] = useState(false)
      return (
        <div>
          <button onClick={() => setPageMounted(false)} type="button">unmount page shortcut</button>
          <button onClick={() => setModalMounted(true)} type="button">mount shadowing shortcut</button>
          {pageMounted ? <Registrant group="Page" keys="mod+k" label="Page action" /> : null}
          {modalMounted ? <Registrant group="Overlay" keys="mod+k" label="Overlay action" /> : null}
          <ShortcutsHelpModal onClose={() => {}} open />
        </div>
      )
    }

    render(
      <ShortcutsProvider>
        <Harness />
      </ShortcutsProvider>
    )

    const dialog = screen.getByRole("dialog")
    expect(within(dialog).getByText("Page action")).toBeInTheDocument()
    expect(within(dialog).queryByText("Overlay action")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "mount shadowing shortcut" }))

    expect(within(dialog).queryByText("Page action")).not.toBeInTheDocument()
    expect(within(dialog).getByText("Overlay action")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "unmount page shortcut" }))

    expect(within(dialog).getByText("Overlay action")).toBeInTheDocument()
  })

  it("shows the empty state when no shortcuts are currently active", () => {
    render(
      <ShortcutsProvider>
        <ShortcutsHelpModal onClose={() => {}} open />
      </ShortcutsProvider>
    )

    expect(within(screen.getByRole("dialog")).getByText("No shortcuts are active right now.")).toBeInTheDocument()
  })

  it("shows parent-layer shortcuts without dispatching them while help is open", () => {
    const onFire = vi.fn()
    render(
      <ShortcutsProvider>
        <Registrant group="Page" keys="g" label="Go elsewhere" onFire={onFire} />
        <ShortcutsHelpModal onClose={() => {}} open />
      </ShortcutsProvider>
    )

    const dialog = screen.getByRole("dialog")
    expect(within(dialog).getByText("Go elsewhere")).toBeInTheDocument()

    fireEvent.keyDown(window, { key: "g" })

    expect(onFire).not.toHaveBeenCalled()
  })

  it("calls onClose from the close button and Escape", () => {
    const onClose = vi.fn()
    render(
      <ShortcutsProvider>
        <ShortcutsHelpModal onClose={onClose} open />
      </ShortcutsProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "Close keyboard shortcuts" }))
    expect(onClose).toHaveBeenCalledTimes(1)

    fireEvent.keyDown(document, { key: "Escape" })
    expect(onClose).toHaveBeenCalledTimes(2)
  })
})

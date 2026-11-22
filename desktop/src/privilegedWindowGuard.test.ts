import { EventEmitter } from "node:events"
import { describe, expect, it } from "vitest"
import { lockPrivilegedWindow } from "../electron/windows/privilegedWindowGuard"

class FakeContents extends EventEmitter {
  openHandler: ((details: { url: string }) => { action: string }) | null = null
  setWindowOpenHandler(handler: (details: { url: string }) => { action: string }) {
    this.openHandler = handler
  }
}

const navigate = (contents: FakeContents, event: string, url: string) => {
  let prevented = false
  contents.emit(event, { preventDefault: () => { prevented = true } }, url)
  return prevented
}

// The tray popover, Preferences and onboarding windows load the local
// renderer with preload.cjs, whose bridge hands out the saved token
// (get-credentials), writes credentials and checks out branches. They had no
// navigation guard: a link or HTML file dropped onto one of them navigated it
// (Electron's default), and the foreign page ran with that bridge attached.
// The main process's own loadFile/loadURL never fires will-navigate, so a
// privileged window may navigate nowhere on its own.
describe("lockPrivilegedWindow", () => {
  it("refuses every renderer-initiated navigation, redirect and popup", () => {
    const contents = new FakeContents()
    lockPrivilegedWindow(contents)

    expect(navigate(contents, "will-navigate", "https://evil.example/steal")).toBe(true)
    expect(navigate(contents, "will-navigate", "file:///Users/me/Downloads/evil.html")).toBe(true)
    expect(navigate(contents, "will-redirect", "https://evil.example/")).toBe(true)
    expect(contents.openHandler?.({ url: "https://evil.example/" })).toEqual({ action: "deny" })
  })
})

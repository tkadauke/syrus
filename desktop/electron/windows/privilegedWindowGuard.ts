// The tray popover, Preferences and onboarding windows load the bundled
// renderer with preload.cjs, whose bridge is privileged: it hands out the
// saved API token, writes credentials, checks out branches and drives the
// installer. Whatever page such a window shows can call that bridge, so the
// window must only ever show what the main process loaded into it.
//
// The main process's own loadFile/loadURL never fires will-navigate, so any
// navigation seen here was started by content — a link or file dropped onto
// the window (Electron navigates to it by default), a link click, or a
// redirect — and is refused. Popups are refused too. Pure: no electron
// import, so the policy is unit-tested directly.

type PreventableEvent = { preventDefault: () => void }

// One overload per event, matching Electron's overloaded WebContents.on.
export type GuardableContents = {
  on(event: "will-navigate", listener: (event: PreventableEvent, url: string) => void): unknown
  on(event: "will-redirect", listener: (event: PreventableEvent, url: string) => void): unknown
  setWindowOpenHandler(handler: (details: { url: string }) => { action: "deny" }): void
}

export const lockPrivilegedWindow = (contents: GuardableContents) => {
  contents.on("will-navigate", (event, url) => {
    console.warn(`[privileged-window] refused navigation to ${url}`)
    event.preventDefault()
  })
  contents.on("will-redirect", (event, url) => {
    console.warn(`[privileged-window] refused redirect to ${url}`)
    event.preventDefault()
  })
  contents.setWindowOpenHandler(() => ({ action: "deny" }))
}

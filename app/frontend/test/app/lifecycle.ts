import { afterEach, beforeEach } from "vitest"
import { __resetDraftAttachmentsForTests } from "../../routes/chat/attachmentDraftStore"
import { actionCable, excalidrawMock, html2canvasMock } from "./appMocks"

// Holds the restore callback installed by mockClipboardWrite so each test
// leaves navigator.clipboard as it found it.
export const clipboardMockState: { restore: (() => void) | null } = { restore: null }

export function resetAppTestState() {
  document.getElementById("syrus-bootstrap-data")?.remove()
  window.localStorage.clear()
  window.localStorage.setItem("syrus.chat.workspace.collapsed", "false")
  document.documentElement.classList.remove("dark")
  excalidrawMock.throwOnRender = false
  excalidrawMock.addFiles.mockClear()
  excalidrawMock.lastInitialData = null
  excalidrawMock.onChange = null
  excalidrawMock.updateScene.mockClear()
  html2canvasMock.mockClear()
  actionCable.createSubscription.mockClear()
  __resetDraftAttachmentsForTests()
}

export function restoreAppTestGlobals() {
  clipboardMockState.restore?.()
  clipboardMockState.restore = null
}

// Call once inside a suite's top-level scope (or describe block).
export function installAppTestLifecycle() {
  beforeEach(resetAppTestState)
  afterEach(restoreAppTestGlobals)
}

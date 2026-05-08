import { Controller } from "@hotwired/stimulus"

// Source tree open/close state preservation.
//
// The server-rendered tree always emits `<details open>` for every
// directory — fine for first paint, awful for active Jobs where each
// Turbo morph (Run state changes, JobLog appends) re-renders the
// `Source` tab and reverts every directory the operator just closed.
//
// This controller layers on top of the server-rendered tree:
//   * On connect, reads a list of closed paths from sessionStorage
//     (keyed by job id) and removes the `open` attribute from any
//     matching `<details>`.
//   * Listens for `toggle` events bubbling up from those `<details>`
//     and writes the new state to sessionStorage.
//
// Why "closed paths" not "open paths"? The default rendering is
// open. Storing the diff (closed-paths) means an operator who opens
// the source tab and never touches it pays no storage cost.
export default class extends Controller {
  static targets = ["dir"]
  static values = {
    jobId: Number,
  }

  connect() {
    this.boundToggle = this.handleToggle.bind(this)
    this.element.addEventListener("toggle", this.boundToggle, true)
    this.applyStoredState()
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.boundToggle, true)
  }

  // Capture every <details>'s toggle event (capture phase so the
  // controller still runs even if some inner handler stops bubbling).
  handleToggle(event) {
    const details = event.target
    if (!details || details.tagName !== "DETAILS") return
    const path = details.dataset.path
    if (!path) return

    const closed = this.loadClosedSet()
    if (details.open) {
      closed.delete(path)
    } else {
      closed.add(path)
    }
    this.saveClosedSet(closed)
  }

  applyStoredState() {
    const closed = this.loadClosedSet()
    if (closed.size === 0) return
    this.dirTargets.forEach((details) => {
      if (closed.has(details.dataset.path)) {
        details.removeAttribute("open")
      }
    })
  }

  // -- storage ---------------------------------------------------

  storageKey() {
    return `syrus:source-tree:closed:${this.jobIdValue}`
  }

  loadClosedSet() {
    try {
      const raw = sessionStorage.getItem(this.storageKey())
      return new Set(raw ? JSON.parse(raw) : [])
    } catch (_e) {
      return new Set()
    }
  }

  saveClosedSet(set) {
    try {
      sessionStorage.setItem(this.storageKey(), JSON.stringify([...set]))
    } catch (_e) {
      // Storage full / disabled — UX degrades to "default open"
      // (the pre-controller behaviour). No-op rather than throw.
    }
  }
}

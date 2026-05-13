import { Controller } from "@hotwired/stimulus"

const DEBOUNCE_MS = 500

export default class extends Controller {
  static targets = ["mount", "broadcast"]
  static values = { url: String }

  connect() {
    this.loaded = false
    this.loading = null
    this.version = 0
    this.pendingElements = null
    this.remoteUpdateInProgress = false
    this.retryingConflict = false

    this.startVisibilityWatch()
  }

  disconnect() {
    this.stopVisibilityWatch()
    this.clearPendingSave()
    if (this.pendingElements) void this.savePending()
    if (this.root) this.root.unmount()
  }

  broadcastTargetConnected(element) {
    if (!this.excalidrawAPI) return

    const version = Number.parseInt(element.dataset.version || "0", 10)
    if (version <= this.version) return

    this.applyRemoteElements(this.parseElements(element.dataset.elementsJson), version)
  }

  startVisibilityWatch() {
    if (this.isVisible()) {
      this.loadAndMount()
      return
    }

    if (!("IntersectionObserver" in window)) return

    this.visibilityObserver = new IntersectionObserver((entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return

      this.stopVisibilityWatch()
      this.loadAndMount()
    })
    this.visibilityObserver.observe(this.element)
  }

  stopVisibilityWatch() {
    if (!this.visibilityObserver) return

    this.visibilityObserver.disconnect()
    this.visibilityObserver = null
  }

  isVisible() {
    return this.element.offsetParent !== null && this.element.getClientRects().length > 0
  }

  async loadAndMount() {
    if (this.loaded || this.loading || !this.hasMountTarget) return

    this.loading = this.performMount()
    await this.loading
  }

  async performMount() {
    const [{ default: React }, { createRoot }, { Excalidraw }] = await Promise.all([
      import("react"),
      import("react-dom/client"),
      import("@excalidraw/excalidraw")
    ])

    this.ensureStylesheet()

    const payload = await this.fetchScene()
    this.version = payload.version

    this.root = createRoot(this.mountTarget)
    this.root.render(
      React.createElement(Excalidraw, {
        initialData: { elements: payload.scene_json.elements },
        excalidrawAPI: (api) => {
          this.excalidrawAPI = api
        },
        onChange: (elements, appState) => this.changed(elements, appState)
      })
    )
    this.loaded = true
    this.queueResize()
  }

  ensureStylesheet() {
    const id = "excalidraw-stylesheet"
    if (document.getElementById(id)) return

    const link = document.createElement("link")
    link.id = id
    link.rel = "stylesheet"
    link.href = "https://esm.sh/@excalidraw/excalidraw@0.18.1/dist/prod/index.css"
    document.head.appendChild(link)
  }

  async fetchScene() {
    const response = await fetch(this.urlValue, {
      headers: { Accept: "application/json" },
      credentials: "same-origin"
    })

    if (!response.ok) throw new Error(`Whiteboard load failed: ${response.status}`)
    return response.json()
  }

  changed(elements, _appState) {
    if (this.remoteUpdateInProgress) return

    this.pendingElements = elements
    this.dispatch("change", { detail: { elements } })
    this.clearPendingSave()
    this.saveTimer = window.setTimeout(() => this.savePending(), DEBOUNCE_MS)
  }

  clearPendingSave() {
    if (!this.saveTimer) return

    window.clearTimeout(this.saveTimer)
    this.saveTimer = null
  }

  async savePending() {
    if (!this.pendingElements) return

    const elements = this.pendingElements
    this.pendingElements = null
    const response = await this.patchElements(elements, this.version)

    if (response.status === 409) {
      await this.recoverConflict(elements)
      return
    }

    if (!response.ok) throw new Error(`Whiteboard save failed: ${response.status}`)

    const payload = await response.json()
    this.version = payload.version
  }

  patchElements(elements, expectedVersion) {
    return fetch(this.urlValue, {
      method: "PATCH",
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ elements, expected_version: expectedVersion })
    })
  }

  async recoverConflict(originalElements) {
    if (this.retryingConflict) return

    this.retryingConflict = true
    try {
      const current = await this.fetchScene()
      this.applyRemoteElements(current.scene_json.elements, current.version)

      const retry = await this.patchElements(originalElements, this.version)
      if (!retry.ok) throw new Error(`Whiteboard conflict retry failed: ${retry.status}`)

      const payload = await retry.json()
      this.version = payload.version
      this.applyRemoteElements(originalElements, this.version)
    } finally {
      this.retryingConflict = false
    }
  }

  applyRemoteElements(elements, version) {
    this.remoteUpdateInProgress = true
    this.excalidrawAPI.updateScene({ elements })
    this.version = version
    queueMicrotask(() => {
      this.remoteUpdateInProgress = false
    })
  }

  parseElements(json) {
    if (!json) return []

    try {
      return JSON.parse(json)
    } catch (_error) {
      return []
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  queueResize() {
    window.requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"))
    })
  }
}

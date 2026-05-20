import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["lane"]
  static values = { subject: String }

  connect() {
    this.handleBeforeMorphElement = (event) => {
      const el = event.target
      if (!(el instanceof Element)) return
      if (!this.element.contains(el)) return

      const openMenu = el.closest("details[open]")
      if (openMenu && this.element.contains(openMenu)) {
        event.preventDefault()
      }
    }
    document.addEventListener("turbo:before-morph-element", this.handleBeforeMorphElement)
  }

  disconnect() {
    document.removeEventListener("turbo:before-morph-element", this.handleBeforeMorphElement)
  }

  dragStart(event) {
    const card = event.currentTarget
    const state = card.dataset.kanbanState

    if (!this.allowsDrag(state)) {
      event.preventDefault()
      return
    }

    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", JSON.stringify({
      id: card.dataset.kanbanId,
      state,
      url: card.dataset.kanbanStateUrl
    }))
  }

  dragOver(event) {
    if (!this.allowsDrop(event)) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
  }

  async drop(event) {
    if (!this.allowsDrop(event)) return

    event.preventDefault()
    const payload = this.dragPayload(event)
    const targetState = this.targetStateFor(payload, event.currentTarget)
    if (!targetState) return

    const response = await fetch(payload.url, {
      method: "PATCH",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ target_state: targetState })
    })

    if (response.ok) {
      window.Turbo?.visit(window.location.href, { action: "replace" })
    }
  }

  allowsDrop(event) {
    const payload = this.dragPayload(event)
    const lane = event.currentTarget

    return this.subjectValue === "epic" && Boolean(this.targetStateFor(payload, lane))
  }

  allowsDrag(state) {
    return this.subjectValue === "epic" && (state === "ready" || state === "in_progress")
  }

  targetStateFor(payload, lane) {
    if (payload?.state === "ready" && lane.dataset.kanbanState === "in_progress") return "in_progress"
    if (payload?.state === "in_progress" && lane.dataset.kanbanState === "ready") return "ready"

    return null
  }

  dragPayload(event) {
    const raw = event.dataTransfer.getData("text/plain")
    if (!raw) return null

    try {
      return JSON.parse(raw)
    } catch {
      return null
    }
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }
}

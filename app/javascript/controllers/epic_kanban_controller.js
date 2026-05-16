import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["lane"]

  dragStart(event) {
    const card = event.currentTarget
    const state = card.dataset.epicState

    if (state !== "ready") {
      event.preventDefault()
      return
    }

    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", JSON.stringify({
      id: card.dataset.epicId,
      state,
      url: card.dataset.epicStateUrl
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
    if (!payload) return

    const response = await fetch(payload.url, {
      method: "PATCH",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify({ target_state: "in_progress" })
    })

    if (response.ok) {
      window.Turbo?.visit(window.location.href, { action: "replace" })
    }
  }

  allowsDrop(event) {
    const payload = this.dragPayload(event)
    const lane = event.currentTarget

    return payload?.state === "ready" && lane.dataset.epicState === "in_progress"
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

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["elapsed"]
  static values = { startedAt: String }

  connect() {
    this.tick()
    this.interval = setInterval(() => this.tick(), 1000)
  }

  disconnect() {
    clearInterval(this.interval)
  }

  tick() {
    const elapsed = Math.floor((Date.now() - new Date(this.startedAtValue)) / 1000)

    if (this.hasElapsedTarget) {
      this.elapsedTarget.textContent = this.formatDuration(elapsed)
    }
  }

  formatDuration(seconds) {
    if (seconds < 60) return `${seconds}s`
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return s > 0 ? `${m}m ${s}s` : `${m}m`
  }
}

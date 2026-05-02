import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["elapsed", "remaining"]
  static values = { startedAt: String, estimatedSeconds: Number }

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

    if (this.hasRemainingTarget) {
      const estimated = this.estimatedSecondsValue
      if (estimated > 0) {
        const remaining = estimated - elapsed
        this.remainingTarget.textContent = remaining > 0
          ? `~${this.formatDuration(remaining)} left`
          : "finishing up…"
      }
    }
  }

  formatDuration(seconds) {
    if (seconds < 60) return `${seconds}s`
    const m = Math.floor(seconds / 60)
    const s = seconds % 60
    return s > 0 ? `${m}m ${s}s` : `${m}m`
  }
}

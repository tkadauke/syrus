import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.update()
    this.interval = setInterval(() => this.update(), 30_000)
  }

  disconnect() {
    clearInterval(this.interval)
  }

  update() {
    const time = new Date(this.element.getAttribute("datetime"))
    const diffSeconds = (Date.now() - time) / 1000
    const future = diffSeconds < 0
    const text = this.format(Math.abs(diffSeconds))
    this.element.textContent = future ? `in ${text}` : `${text} ago`
  }

  format(seconds) {
    const minutes = Math.round(seconds / 60)
    const hours = Math.round(seconds / 3600)
    const days = Math.round(seconds / 86400)
    const months = Math.round(seconds / 2592000)
    const years = Math.round(seconds / 31536000)

    if (seconds < 45) return "less than a minute"
    if (seconds < 90) return "1 minute"
    if (minutes < 45) return `${minutes} minutes`
    if (minutes < 90) return "about 1 hour"
    if (hours < 24) return `about ${hours} hours`
    if (hours < 42) return "1 day"
    if (days < 30) return `${days} days`
    if (days < 45) return "about 1 month"
    if (days < 365) return `${months} months`
    if (days < 548) return "about 1 year"
    return `${years} years`
  }
}

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "choice", "position", "previous", "submit"]

  connect() {
    this.index = 0
    this.render()
  }

  approve() {
    this.choiceTargets[this.index].value = "approve"
    this.next()
  }

  skip() {
    this.choiceTargets[this.index].value = "skip"
    this.next()
  }

  previous() {
    if (this.index > 0) {
      this.index -= 1
      this.render()
    }
  }

  next() {
    if (this.index < this.itemTargets.length - 1) {
      this.index += 1
    }
    this.render()
  }

  render() {
    this.itemTargets.forEach((item, itemIndex) => {
      item.classList.toggle("hidden", itemIndex !== this.index)
    })
    this.positionTarget.textContent = (this.index + 1).toString()
    this.previousTarget.disabled = this.index === 0
    this.previousTarget.classList.toggle("opacity-50", this.index === 0)
    this.submitTarget.classList.toggle("hidden", this.index !== this.itemTargets.length - 1)
  }
}

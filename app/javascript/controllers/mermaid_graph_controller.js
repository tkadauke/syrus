import { Controller } from "@hotwired/stimulus"
import mermaid from "mermaid"

let renderSequence = 0
let initialized = false

export default class extends Controller {
  static targets = ["source", "output"]

  connect() {
    if (!initialized) {
      mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "base" })
      initialized = true
    }

    this.render()
  }

  async render() {
    const definition = this.sourceTarget.textContent.trim()
    if (!definition) return

    const renderId = `epic-dependency-graph-${++renderSequence}`
    try {
      const { svg, bindFunctions } = await mermaid.render(renderId, definition)
      if (!this.element.isConnected) return

      this.outputTarget.innerHTML = svg
      bindFunctions?.(this.outputTarget)
    } catch (error) {
      this.outputTarget.innerHTML = ""
      const message = document.createElement("p")
      message.className = "text-sm text-red-700"
      message.textContent = `Dependency graph could not render: ${error.message || error}`
      this.outputTarget.appendChild(message)
    }
  }
}

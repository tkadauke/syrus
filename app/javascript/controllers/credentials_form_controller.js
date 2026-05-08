import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "agentProviderSelect",
    "claudeSection",
    "codexAuthModeSection",
    "codexAuthModeSelect",
    "codexApiKeySection",
    "codexAuthJsonSection"
  ]

  connect() {
    this.updateVisibility()
  }

  agentProviderChanged() {
    this.updateVisibility()
  }

  codexAuthModeChanged() {
    this.updateVisibility()
  }

  updateVisibility() {
    const provider = this.agentProviderSelectTarget.value
    const codexAuthMode = this.hasCodexAuthModeSelectTarget ? this.codexAuthModeSelectTarget.value : ""
    const codexSelected = provider === "codex"

    this.setSectionVisible(this.claudeSectionTarget, provider === "claude")
    this.setSectionVisible(this.codexAuthModeSectionTarget, codexSelected)
    this.setSectionVisible(this.codexApiKeySectionTarget, codexSelected && codexAuthMode === "api_key")
    this.setSectionVisible(this.codexAuthJsonSectionTarget, codexSelected && codexAuthMode === "chatgpt_login")
  }

  setSectionVisible(section, visible) {
    section.classList.toggle("hidden", !visible)
    section.querySelectorAll("input, select, textarea").forEach((field) => {
      field.disabled = !visible
    })
  }
}

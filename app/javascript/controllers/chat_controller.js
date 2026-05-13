import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["stream", "newMessagesPill", "textarea", "sendButton", "stopButton"]
  static values = { turnInFlight: Boolean }

  connect() {
    this.wasNearBottom = true
    this.scrollToBottom()
    this.updateCompose()
    this.observer = new MutationObserver(() => this.messagesChanged())
    this.observer.observe(this.streamTarget, { childList: true })
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  turnInFlightValueChanged() {
    this.updateCompose()
  }

  scroll() {
    this.wasNearBottom = this.isNearBottom()
    if (this.wasNearBottom) this.hideNewMessagesPill()
  }

  messagesChanged() {
    if (this.wasNearBottom || this.isNearBottom()) {
      this.scrollToBottom()
    } else {
      this.showNewMessagesPill()
    }
  }

  scrollToBottom() {
    if (!this.hasStreamTarget) return

    this.streamTarget.scrollTop = this.streamTarget.scrollHeight
    this.wasNearBottom = true
    this.hideNewMessagesPill()
  }

  updateCompose() {
    const disabled = this.turnInFlightValue
    if (this.hasTextareaTarget) this.textareaTarget.disabled = disabled
    if (this.hasSendButtonTarget) this.sendButtonTarget.disabled = disabled
  }

  stop() {
    if (!this.hasStopButtonTarget) return

    this.stopButtonTarget.disabled = true
    this.stopButtonTarget.value = "Stopping…"
    this.stopButtonTarget.textContent = "Stopping…"
  }

  isNearBottom() {
    if (!this.hasStreamTarget) return true

    return this.streamTarget.scrollHeight - this.streamTarget.scrollTop - this.streamTarget.clientHeight < 64
  }

  showNewMessagesPill() {
    if (this.hasNewMessagesPillTarget) this.newMessagesPillTarget.classList.remove("hidden")
  }

  hideNewMessagesPill() {
    if (this.hasNewMessagesPillTarget) this.newMessagesPillTarget.classList.add("hidden")
  }
}

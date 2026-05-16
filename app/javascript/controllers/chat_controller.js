import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["stream", "newMessagesPill", "textarea", "sendButton", "stopButton", "whiteboard", "whiteboardPlaceholder", "proposalDialog"]
  static values = {
    turnInFlight: Boolean,
    olderMessagesUrl: String,
    hasMoreOlder: Boolean,
  }

  connect() {
    this.wasNearBottom = true
    this.loadingOlder = false
    // Defer the initial scroll one frame so any layout work the
    // sibling controllers do during their own connect — chat-layout
    // reparents this pane into a slot, which resets scrollTop — has
    // settled before we anchor to the bottom. Fall back to a sync
    // call in the JS unit test env where rAF is undefined.
    if (typeof requestAnimationFrame === "function") {
      requestAnimationFrame(() => {
        this.scrollToBottom()
        this.fillViewportWithHistory()
      })
    } else {
      this.scrollToBottom()
    }
    this.updateCompose()
    this.syncWhiteboardPlaceholder()
    if (this.hasStreamTarget) {
      this.observer = new MutationObserver(() => this.messagesChanged())
      this.observer.observe(this.streamTarget, { childList: true })
    }
  }

  // Compact grouped messages can render so densely that the latest
  // page doesn't fill the chat pane — leaving nothing to scroll
  // *up* into, which means infinite-scroll-up never triggers. Pull
  // older pages on first paint until the stream is scrollable (or
  // there are no more older messages). Capped to a few iterations
  // to keep an empty-result loop from running away.
  async fillViewportWithHistory() {
    if (!this.hasStreamTarget) return
    if (typeof fetch !== "function") return

    const MAX_FILLS = 10
    for (let i = 0; i < MAX_FILLS; i++) {
      if (!this.hasMoreOlderValue) break
      if (this.streamTarget.scrollHeight > this.streamTarget.clientHeight + 50) break

      const before = this.streamTarget.scrollHeight
      await this.loadOlderMessages()
      // If the call was a no-op (no messages found, fetch failed,
      // etc.) stop — otherwise we'd burn the cap on identical noops.
      if (this.streamTarget.scrollHeight === before) break
    }
    this.scrollToBottom()
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  turnInFlightValueChanged() {
    this.updateCompose()
  }

  whiteboardTargetConnected() {
    this.syncWhiteboardPlaceholder()
  }

  textareaTargetConnected() {
    this.autoGrow()
  }

  autoGrow() {
    if (!this.hasTextareaTarget) return

    const ta = this.textareaTarget
    // Reset to auto so the next read of scrollHeight reflects current
    // content rather than the previously-set height; the CSS max-h on
    // the element caps growth, after which the textarea scrolls.
    ta.style.height = "auto"
    ta.style.height = `${ta.scrollHeight}px`
  }

  // On desktop, Enter submits and Shift+Enter inserts a newline
  // (textarea default). On mobile, Enter should keep its native
  // newline behavior because soft keyboards do not expose Shift+Enter.
  // Ignore IME composition keys so non-Latin input methods that
  // commit on Enter aren't hijacked. Click the actual submit
  // button rather than calling form.requestSubmit() so the path is
  // identical to a real Send click — same submitter, same Turbo
  // interception, no surprises.
  submitOnEnter(event) {
    if (event.key !== "Enter") return
    if (event.shiftKey) return
    if (this.isMobileInput()) return
    if (event.isComposing) return
    if (!this.hasTextareaTarget) return
    if (this.textareaTarget.disabled) return

    const form = this.textareaTarget.closest("form")
    if (!form) return

    const submitter = form.querySelector('input[type="submit"], button[type="submit"]')
    if (!submitter || submitter.disabled) return

    event.preventDefault()
    submitter.click()
  }

  openProposalModal(event) {
    const dialogId = event.currentTarget?.dataset?.chatProposalDialogId
    const dialog = this.proposalDialogTargets.find((candidate) => candidate.id === dialogId)
    if (!dialog || typeof dialog.showModal !== "function") return

    dialog.showModal()
  }

  closeProposalModal(event) {
    const dialog = event.currentTarget?.closest?.("dialog")
    if (!dialog || typeof dialog.close !== "function") return

    dialog.close()
  }

  isMobileInput() {
    if (typeof window === "undefined") return false
    if (typeof window.matchMedia !== "function") return false

    return window.matchMedia("(pointer: coarse), (max-width: 767px)").matches
  }

  scroll() {
    this.wasNearBottom = this.isNearBottom()
    if (this.wasNearBottom) this.hideNewMessagesPill()
    if (this.isNearTop()) this.loadOlderMessages()
  }

  isNearTop() {
    if (!this.hasStreamTarget) return false
    return this.streamTarget.scrollTop < 120
  }

  async loadOlderMessages() {
    if (this.loadingOlder) return
    if (!this.hasMoreOlderValue) return
    if (!this.hasOlderMessagesUrlValue || !this.olderMessagesUrlValue) return
    if (!this.hasStreamTarget) return

    const first = this.streamTarget.querySelector("[data-message-id]")
    if (!first) return
    const beforeId = first.dataset.messageId
    if (!beforeId) return

    this.loadingOlder = true
    try {
      const response = await fetch(`${this.olderMessagesUrlValue}?before=${encodeURIComponent(beforeId)}`, {
        headers: { Accept: "text/html" },
        credentials: "same-origin",
      })
      if (!response.ok) return

      const hasMoreHeader = response.headers.get("X-Chat-Has-More-Older")
      if (hasMoreHeader !== null) {
        this.hasMoreOlderValue = hasMoreHeader === "true"
      }

      const html = await response.text()
      if (!html.trim()) return

      // Preserve the user's visual scroll position: prepending taller
      // content would otherwise leave them looking at a different
      // section of the conversation.
      const prevScrollHeight = this.streamTarget.scrollHeight
      const prevScrollTop = this.streamTarget.scrollTop
      first.insertAdjacentHTML("beforebegin", html)
      this.streamTarget.scrollTop = prevScrollTop + (this.streamTarget.scrollHeight - prevScrollHeight)
    } finally {
      this.loadingOlder = false
    }
  }

  messagesChanged() {
    // Prepending older messages also fires the mutation observer.
    // Don't auto-scroll or surface the "new messages" pill in that
    // case — the change happened above the viewport, not below.
    if (this.loadingOlder) return

    this.mergeLiveToolCalls()
    this.pairLiveToolResults()

    if (this.wasNearBottom || this.isNearBottom()) {
      this.scrollToBottom()
    } else {
      this.showNewMessagesPill()
    }
  }

  // Server-side, ChatMessageGrouper folds consecutive same-name
  // tool_use messages into one collapsed group. Live appends arrive
  // one at a time, so do the same fold client-side: if the newly
  // appended group has the same data-tool-name as the previous tool
  // call group, merge its detail + body cells into the previous one
  // and drop the new wrapper.
  mergeLiveToolCalls() {
    if (!this.hasStreamTarget) return
    if (typeof this.streamTarget.querySelectorAll !== "function") return

    const newGroups = this.streamTarget.querySelectorAll('details[data-tool-call="true"]:not([data-tool-call-merged])')
    newGroups.forEach(group => {
      // The element appended to streamTarget is the outer
      // _message.html.erb wrapper; the details element is one level
      // down. On initial render the details is the top-level child,
      // and we never want to merge across those — guard by requiring
      // a carrier wrapper.
      const carrier = group.parentElement
      if (!carrier || carrier.parentElement !== this.streamTarget) {
        group.setAttribute("data-tool-call-merged", "true")
        return
      }

      // Walk back, skipping hidden tool-result carriers from prior
      // pairing — they don't break grouping continuity. Stop at the
      // first carrier that actually contains a tool-call details (or
      // an unrelated message, which means merge fails).
      let candidate = carrier.previousElementSibling
      let prevGroup = null
      while (candidate) {
        if (candidate.classList?.contains("hidden") &&
            candidate.querySelector?.('[data-tool-call-result="true"]')) {
          candidate = candidate.previousElementSibling
          continue
        }
        prevGroup = candidate.matches?.('details[data-tool-call="true"]')
          ? candidate
          : candidate.querySelector?.(':scope > details[data-tool-call="true"]')
        break
      }
      if (!prevGroup || prevGroup.dataset.toolName !== group.dataset.toolName) {
        group.setAttribute("data-tool-call-merged", "true")
        return
      }

      const newDetail = group.querySelector('[data-tool-detail]')?.textContent?.trim() || ""
      if (newDetail) {
        const prevDetail = prevGroup.querySelector('[data-tool-detail]')
        if (prevDetail) {
          const existing = prevDetail.textContent.trim()
          prevDetail.textContent = existing ? `${existing}, ${newDetail}` : newDetail
        }
      }

      const prevBody = prevGroup.querySelector('[data-tool-call-body]')
      const newBody = group.querySelector('[data-tool-call-body]')
      if (prevBody && newBody) {
        while (newBody.firstChild) prevBody.appendChild(newBody.firstChild)
      }

      const prevCount = prevGroup.querySelector('[data-tool-call-count]')
      if (prevCount) {
        const next = parseInt(prevCount.textContent.trim() || "1", 10) + 1
        prevCount.textContent = String(next)
        prevCount.classList.remove("hidden")
      }

      group.setAttribute("data-tool-call-merged", "true")
      carrier.remove()
    })
  }

  // Server-side, ChatMessageGrouper folds each tool_result into the
  // preceding tool_use group's expand body. Live appends arrive as
  // separate messages, so do the same fold client-side: find each
  // newly-appended result marker and move its body into the previous
  // tool-call group's body, then hide the result wrapper. Idempotent
  // via the `data-tool-result-paired` marker.
  pairLiveToolResults() {
    if (!this.hasStreamTarget) return
    if (typeof this.streamTarget.querySelectorAll !== "function") return

    const results = this.streamTarget.querySelectorAll('[data-tool-call-result="true"]:not([data-tool-result-paired])')
    results.forEach(result => {
      const wrapper = result.closest('.chat-message')
      const outer = wrapper && wrapper.parentElement === this.streamTarget ? wrapper : wrapper?.parentElement
      const carrier = outer || wrapper
      if (!carrier) return

      let prev = carrier.previousElementSibling
      let body = null
      while (prev && !(body = prev.querySelector('[data-tool-call-body]'))) {
        prev = prev.previousElementSibling
      }
      if (!body) return

      const content = result.querySelector('pre')
      if (!content) return

      const cell = document.createElement('div')
      cell.appendChild(content.cloneNode(true))
      body.appendChild(cell)

      result.setAttribute('data-tool-result-paired', 'true')
      carrier.classList.add('hidden')
    })
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

  whiteboardChanged(event) {
    const elements = event.detail?.elements || []
    this.setWhiteboardPlaceholderVisible(elements.length === 0)
  }

  syncWhiteboardPlaceholder() {
    if (!this.hasWhiteboardTarget) return

    try {
      const scene = JSON.parse(this.whiteboardTarget.dataset.whiteboardScene || "{}")
      const elements = Array.isArray(scene.elements) ? scene.elements : []
      this.setWhiteboardPlaceholderVisible(elements.length === 0)
    } catch {
      this.setWhiteboardPlaceholderVisible(true)
    }
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

  setWhiteboardPlaceholderVisible(visible) {
    if (this.hasWhiteboardPlaceholderTarget) this.whiteboardPlaceholderTarget.classList.toggle("hidden", !visible)
  }
}

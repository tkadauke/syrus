import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["owner", "name", "branchText", "branchSelect", "repoError"]

  connect() {
    this.debounceTimer = null
    // On edit form, if fields are already populated, fetch branches immediately.
    if (this.ownerTarget.value.trim() && this.nameTarget.value.trim()) {
      this.doFetch(this.ownerTarget.value.trim(), this.nameTarget.value.trim())
    }
  }

  fetchBranches() {
    clearTimeout(this.debounceTimer)
    const owner = this.ownerTarget.value.trim()
    const name = this.nameTarget.value.trim()

    if (!owner || !name) {
      this.resetBranchField()
      this.hideRepoError()
      return
    }

    this.debounceTimer = setTimeout(() => this.doFetch(owner, name), 500)
  }

  async doFetch(owner, name) {
    try {
      const url = `/repositories/branches?owner=${encodeURIComponent(owner)}&name=${encodeURIComponent(name)}`
      const resp = await fetch(url, {
        headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken }
      })
      const data = await resp.json()

      if (data.error === "not_found") {
        this.showRepoError("Repository not found or not accessible")
        this.resetBranchField()
      } else if (data.error) {
        this.hideRepoError()
        this.resetBranchField()
      } else {
        this.hideRepoError()
        this.populateBranches(data.branches, data.default_branch)
      }
    } catch (_e) {
      // network error — leave the UI as-is
    }
  }

  populateBranches(branches, defaultBranch) {
    const select = this.branchSelectTarget
    const text = this.branchTextTarget
    // Prefer the current user-entered value; fall back to GitHub's default.
    const currentValue = text.value.trim() || defaultBranch

    select.innerHTML = branches
      .map(b => `<option value="${this.escapeHtml(b)}"${b === currentValue ? " selected" : ""}>${this.escapeHtml(b)}</option>`)
      .join("")

    text.disabled = true
    text.classList.add("hidden")
    select.disabled = false
    select.classList.remove("hidden")
  }

  resetBranchField() {
    const select = this.branchSelectTarget
    const text = this.branchTextTarget

    select.disabled = true
    select.classList.add("hidden")
    select.innerHTML = ""
    text.disabled = false
    text.classList.remove("hidden")
  }

  hideRepoError() {
    this.repoErrorTarget.textContent = ""
    this.repoErrorTarget.classList.add("hidden")
  }

  showRepoError(message) {
    this.repoErrorTarget.textContent = message
    this.repoErrorTarget.classList.remove("hidden")
  }

  escapeHtml(str) {
    return str.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content ?? ""
  }
}

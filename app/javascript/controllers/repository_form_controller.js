import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "ownerText", "ownerSelect", "ownerManualLink",
    "nameText", "nameSelect", "nameManualLink",
    "branchText", "branchSelect",
    "githubRepositoryId", "githubOwnerId",
    "repoError"
  ]

  connect() {
    this.branchDebounceTimer = null
    this.ownerTypes = {}  // login → "user" | "org"
    this.fetchOwners()
  }

  // ── Owner ──────────────────────────────────────────────────────────────────

  async fetchOwners() {
    try {
      const resp = await fetch("/repositories/owners", {
        headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken }
      })
      const data = await resp.json()
      if (data.error) return

      const owners = []
      if (data.user) {
        this.ownerTypes[data.user] = "user"
        owners.push(data.user)
      }
      ;(data.orgs || []).forEach(org => {
        this.ownerTypes[org] = "org"
        owners.push(org)
      })

      if (owners.length > 0) this.populateOwners(owners)
    } catch (_e) {
      // network error — leave text input visible
    }
  }

  populateOwners(owners) {
    const text   = this.ownerTextTarget
    const select = this.ownerSelectTarget
    const current = text.value.trim()

    select.innerHTML =
      '<option value="">Select owner…</option>' +
      owners.map(o =>
        `<option value="${this.esc(o)}"${o === current ? " selected" : ""}>${this.esc(o)}</option>`
      ).join("")

    this.showSelect(text, select)
    this.ownerManualLinkTarget.classList.remove("hidden")

    // Edit form: owner already set — immediately fetch its repos
    if (current && this.ownerTypes[current]) {
      this.fetchRepos(current, this.ownerTypes[current])
    }
  }

  ownerSelected() {
    const owner = this.ownerSelectTarget.value
    this.ownerTextTarget.value = owner
    this.resetNameField()
    this.resetBranchField()
    if (!owner) return
    this.fetchRepos(owner, this.ownerTypes[owner] || "org")
  }

  enterOwnerManually(event) {
    event.preventDefault()
    this.showText(this.ownerTextTarget, this.ownerSelectTarget)
    this.ownerManualLinkTarget.classList.add("hidden")
    this.resetNameField()
    this.resetBranchField()
  }

  ownerTextChanged() {
    this.resetNameField()
    this.resetBranchField()
    this.scheduleBranchFetch()
  }

  // ── Name / Repo ────────────────────────────────────────────────────────────

  async fetchRepos(owner, ownerType) {
    try {
      const url = `/repositories/repos?owner=${encodeURIComponent(owner)}&owner_type=${encodeURIComponent(ownerType)}`
      const resp = await fetch(url, {
        headers: { "Accept": "application/json", "X-CSRF-Token": this.csrfToken }
      })
      const data = await resp.json()
      if (!data.error && data.repos) this.populateRepos(data.repos, owner)
    } catch (_e) {
      // network error — leave name text input
    }
  }

  populateRepos(repos, owner) {
    const text   = this.nameTextTarget
    const select = this.nameSelectTarget
    const current = text.value.trim()
    this.repoMetadata = {}

    select.innerHTML =
      '<option value="">Select repository…</option>' +
      repos.map(repo => {
        const name = typeof repo === "string" ? repo : repo.name
        this.repoMetadata[name] = {
          githubRepositoryId: repo.github_repository_id,
          githubOwnerId: repo.github_owner_id
        }
        return `<option value="${this.esc(name)}"${name === current ? " selected" : ""}>${this.esc(name)}</option>`
      }
      ).join("")

    this.showSelect(text, select)
    this.nameManualLinkTarget.classList.remove("hidden")

    // Edit form: name already set — fetch branches
    if (current && this.repoMetadata[current]) {
      this.setGithubIds(current)
      this.doFetchBranches(owner, current)
    }
  }

  nameSelected() {
    const name = this.nameSelectTarget.value
    this.nameTextTarget.value = name
    this.setGithubIds(name)
    this.resetBranchField()
    this.hideRepoError()
    if (!name) return
    const owner = this.currentOwner
    if (owner) this.doFetchBranches(owner, name)
  }

  enterNameManually(event) {
    event.preventDefault()
    this.showText(this.nameTextTarget, this.nameSelectTarget)
    this.nameManualLinkTarget.classList.add("hidden")
    this.clearGithubIds()
    this.resetBranchField()
  }

  nameTextChanged() {
    this.clearGithubIds()
    this.resetBranchField()
    this.scheduleBranchFetch()
  }

  // ── Branches (unchanged logic, factored) ──────────────────────────────────

  scheduleBranchFetch() {
    clearTimeout(this.branchDebounceTimer)
    const owner = this.currentOwner
    const name  = this.currentName
    if (!owner || !name) { this.hideRepoError(); return }
    this.branchDebounceTimer = setTimeout(() => this.doFetchBranches(owner, name), 500)
  }

  async doFetchBranches(owner, name) {
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
      // network error — leave UI as-is
    }
  }

  populateBranches(branches, defaultBranch) {
    const select = this.branchSelectTarget
    const text   = this.branchTextTarget
    const current = text.value.trim() || defaultBranch

    select.innerHTML = branches
      .map(b => `<option value="${this.esc(b)}"${b === current ? " selected" : ""}>${this.esc(b)}</option>`)
      .join("")

    this.showSelect(text, select)
  }

  // ── Reset helpers ──────────────────────────────────────────────────────────

  resetNameField() {
    const select = this.nameSelectTarget
    const text   = this.nameTextTarget
    select.disabled = true
    select.classList.add("hidden")
    select.innerHTML = ""
    text.disabled = false
    text.classList.remove("hidden")
    if (this.hasNameManualLinkTarget) this.nameManualLinkTarget.classList.add("hidden")
    this.clearGithubIds()
  }

  resetBranchField() {
    const select = this.branchSelectTarget
    const text   = this.branchTextTarget
    select.disabled = true
    select.classList.add("hidden")
    select.innerHTML = ""
    text.disabled = false
    text.classList.remove("hidden")
  }

  // ── Error display ──────────────────────────────────────────────────────────

  hideRepoError() {
    this.repoErrorTarget.textContent = ""
    this.repoErrorTarget.classList.add("hidden")
  }

  showRepoError(message) {
    this.repoErrorTarget.textContent = message
    this.repoErrorTarget.classList.remove("hidden")
  }

  setGithubIds(name) {
    const metadata = this.repoMetadata?.[name]
    this.githubRepositoryIdTarget.value = metadata?.githubRepositoryId || ""
    this.githubOwnerIdTarget.value = metadata?.githubOwnerId || ""
  }

  clearGithubIds() {
    this.githubRepositoryIdTarget.value = ""
    this.githubOwnerIdTarget.value = ""
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  showSelect(text, select) {
    text.disabled = true
    text.classList.add("hidden")
    select.disabled = false
    select.classList.remove("hidden")
  }

  showText(text, select) {
    select.disabled = true
    select.classList.add("hidden")
    text.disabled = false
    text.classList.remove("hidden")
    text.focus()
  }

  get currentOwner() {
    const sel = this.ownerSelectTarget
    if (!sel.classList.contains("hidden")) return sel.value
    return this.ownerTextTarget.value.trim()
  }

  get currentName() {
    const sel = this.nameSelectTarget
    if (!sel.classList.contains("hidden")) return sel.value
    return this.nameTextTarget.value.trim()
  }

  esc(str) {
    return str.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content ?? ""
  }
}

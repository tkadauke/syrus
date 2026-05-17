import { Controller } from "@hotwired/stimulus"

const FILTER_KEYS = ["q", "state", "repository_id", "pr", "age", "attention", "tag_ids[]"]
const LEGACY_STORAGE_KEY = "dashboard_job_filters"
const EMPTY_Q_VALUES = new Set(["eyJhbmQiOltdfQ", "eyJhbmQiOltd9", ""])

export default class extends Controller {
  static values = {
    subject: { type: String, default: "job" }
  }

  connect() {
    const params = new URLSearchParams(window.location.search)
    if (params.has("smart_folder_id")) return
    const storage = globalThis.localStorage || globalThis.sessionStorage
    const storageKey = `syrus.filter.last:${this.subjectValue || "job"}`

    const active = {}
    let hasFilters = false
    let hasSubmittedFilterParams = false

    for (const key of FILTER_KEYS) {
      if (params.has(key)) {
        hasSubmittedFilterParams = true
      }

      const values = params.getAll(key).filter((value) => !this.blankFilterValue(key, value))
      if (values.length > 0) {
        active[key] = values
        hasFilters = true
      }
    }

    if (hasFilters) {
      const storedParams = new URLSearchParams()
      for (const [key, values] of Object.entries(active)) {
        values.forEach((value) => storedParams.append(key, value))
      }
      storage.setItem(storageKey, storedParams.toString())
    } else if (hasSubmittedFilterParams) {
      storage.removeItem(storageKey)
    } else if (!params.has("view")) {
      const stored = storage.getItem(storageKey) || (this.subjectValue === "job" ? storage.getItem(LEGACY_STORAGE_KEY) : null)
      if (stored) {
        window.location.replace(`${this.restorePath}?${stored}`)
      }
    }
  }

  clear() {
    const storage = globalThis.localStorage || globalThis.sessionStorage
    storage.removeItem(`syrus.filter.last:${this.subjectValue || "job"}`)
  }

  get restorePath() {
    if (window.location.pathname) return window.location.pathname
    return this.subjectValue === "epic" ? "/epics" : "/dashboard/jobs"
  }

  blankFilterValue(key, value) {
    if (!value) return true
    return key === "q" && EMPTY_Q_VALUES.has(value)
  }
}

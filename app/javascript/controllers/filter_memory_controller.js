import { Controller } from "@hotwired/stimulus"

const FILTER_KEYS = ["state", "repository_id", "pr", "age"]
const STORAGE_KEY = "dashboard_job_filters"

export default class extends Controller {
  connect() {
    const params = new URLSearchParams(window.location.search)
    const active = {}
    let hasFilters = false
    let hasSubmittedFilterParams = false

    for (const key of FILTER_KEYS) {
      if (params.has(key)) {
        hasSubmittedFilterParams = true
      }

      const val = params.get(key)
      if (val) {
        active[key] = val
        hasFilters = true
      }
    }

    if (hasFilters) {
      sessionStorage.setItem(STORAGE_KEY, new URLSearchParams(active).toString())
    } else if (hasSubmittedFilterParams) {
      sessionStorage.removeItem(STORAGE_KEY)
    } else {
      const stored = sessionStorage.getItem(STORAGE_KEY)
      if (stored) {
        window.location.replace(`/?${stored}`)
      }
    }
  }

  clear() {
    sessionStorage.removeItem(STORAGE_KEY)
  }
}

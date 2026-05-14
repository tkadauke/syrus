import { Controller } from "@hotwired/stimulus"

const FILTER_KEYS = ["state", "repository_id", "pr", "age", "attention", "tag_ids[]"]
const STORAGE_KEY = "dashboard_job_filters"

export default class extends Controller {
  connect() {
    const params = new URLSearchParams(window.location.search)
    if (params.has("smart_folder_id")) return

    const active = {}
    let hasFilters = false
    let hasSubmittedFilterParams = false

    for (const key of FILTER_KEYS) {
      if (params.has(key)) {
        hasSubmittedFilterParams = true
      }

      const values = params.getAll(key).filter((value) => value)
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
      sessionStorage.setItem(STORAGE_KEY, storedParams.toString())
    } else if (hasSubmittedFilterParams) {
      sessionStorage.removeItem(STORAGE_KEY)
    } else if (!params.has("view")) {
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

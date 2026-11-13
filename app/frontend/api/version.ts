import { reloadPage } from "../lib/pageReload"

export const EXPECTED_API_VERSION = 1
export const API_VERSION_MISMATCH_EVENT = "syrus:api-version-mismatch"

const MISMATCH_STORAGE_KEY = "syrus:api-version-mismatch"
const RELOAD_STORAGE_KEY = "syrus:api-version-reload"

export type ApiEnvelope = {
  v?: number
}

export type ApiVersionMismatch = {
  actual: number
  expected: number
}

export function checkApiVersion(payload: unknown): boolean {
  if (!payload || typeof payload !== "object" || !("v" in payload)) return true

  const actual = (payload as ApiEnvelope).v
  if (typeof actual !== "number") return true
  if (actual === EXPECTED_API_VERSION) {
    clearApiVersionMismatch()
    return true
  }

  const mismatch = { actual, expected: EXPECTED_API_VERSION }
  persistMismatch(mismatch)
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent<ApiVersionMismatch>(API_VERSION_MISMATCH_EVENT, { detail: mismatch }))
  }
  triggerVersionReloadOnce(mismatch)
  return false
}

export function readApiVersionMismatch(): ApiVersionMismatch | null {
  if (typeof window === "undefined") return null

  try {
    const stored = window.sessionStorage.getItem(MISMATCH_STORAGE_KEY)
    if (!stored) return null
    const mismatch = JSON.parse(stored) as Partial<ApiVersionMismatch>
    return typeof mismatch.actual === "number" && typeof mismatch.expected === "number" ? (mismatch as ApiVersionMismatch) : null
  } catch {
    return null
  }
}

function clearApiVersionMismatch() {
  if (typeof window === "undefined") return
  try {
    window.sessionStorage.removeItem(MISMATCH_STORAGE_KEY)
  } catch {
    // Storage may be unavailable in private or locked-down contexts.
  }
}

function persistMismatch(mismatch: ApiVersionMismatch) {
  if (typeof window === "undefined") return
  try {
    window.sessionStorage.setItem(MISMATCH_STORAGE_KEY, JSON.stringify(mismatch))
  } catch {
    // The in-page event still displays the warning when storage is unavailable.
  }
}

function triggerVersionReloadOnce(mismatch: ApiVersionMismatch) {
  if (typeof window === "undefined") return

  const key = `${mismatch.expected}->${mismatch.actual}`
  try {
    if (window.sessionStorage.getItem(RELOAD_STORAGE_KEY) === key) return
    window.sessionStorage.setItem(RELOAD_STORAGE_KEY, key)
  } catch {
    // Continue with one best-effort reload when storage cannot provide a guard.
  }

  const updateWorker =
    typeof navigator !== "undefined" && "serviceWorker" in navigator
      ? navigator.serviceWorker.getRegistration().then((registration) => registration?.update())
      : Promise.resolve()
  void updateWorker.catch(() => undefined).finally(reloadPage)
}

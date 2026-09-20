const MAX_ERRORS = 10

export type RecentError = {
  message: string
  source: string
  at: string
  count: number
}

const recentErrors: RecentError[] = []

let errorHandler: ((e: ErrorEvent) => void) | null = null
let rejectionHandler: ((e: PromiseRejectionEvent) => void) | null = null

function recordError(message: string, source: string) {
  const trimmedMessage = String(message).slice(0, 500)
  const at = new Date().toISOString()

  const existing = recentErrors.find((e) => e.message === trimmedMessage && e.source === source)
  if (existing) {
    existing.count += 1
    existing.at = at
    return
  }

  recentErrors.push({ message: trimmedMessage, source, at, count: 1 })
  if (recentErrors.length > MAX_ERRORS) recentErrors.shift()
}

export function initErrorRingBuffer() {
  if (errorHandler) return

  errorHandler = (event: ErrorEvent) => {
    recordError(event.message || "Unknown error", event.filename || "unknown")
  }
  rejectionHandler = (event: PromiseRejectionEvent) => {
    const message =
      event.reason instanceof Error ? event.reason.message : String(event.reason ?? "Unhandled rejection")
    recordError(message, "promise")
  }

  window.addEventListener("error", errorHandler)
  window.addEventListener("unhandledrejection", rejectionHandler)
}

export function getRecentErrors(): RecentError[] {
  return recentErrors.map((error) => ({ ...error }))
}

export function _clearRecentErrors() {
  recentErrors.length = 0

  if (errorHandler) {
    window.removeEventListener("error", errorHandler)
    errorHandler = null
  }
  if (rejectionHandler) {
    window.removeEventListener("unhandledrejection", rejectionHandler)
    rejectionHandler = null
  }
}

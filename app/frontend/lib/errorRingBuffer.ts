const MAX_ERRORS = 10

export type RecentError = {
  message: string
  source: string
  at: string
}

const recentErrors: RecentError[] = []

let errorHandler: ((e: ErrorEvent) => void) | null = null
let rejectionHandler: ((e: PromiseRejectionEvent) => void) | null = null

function recordError(message: string, source: string) {
  recentErrors.push({ message: String(message).slice(0, 500), source, at: new Date().toISOString() })
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
  return [...recentErrors]
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

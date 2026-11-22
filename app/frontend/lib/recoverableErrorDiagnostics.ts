import { buildBrowserErrorPayload, recordBrowserError, scrubBrowserErrorText, type BrowserErrorPayload } from "../api/browserErrors"
import { computeBrowserErrorFingerprint } from "./browserErrorFingerprint"

const RESOURCE_LIMIT = 8
const RESOURCE_LOOKBACK_MS = 30_000
const INTERACTION_MAX_AGE_MS = 30_000
const TEST_ID_MAX_LENGTH = 100
const TRACKED_EVENTS = ["click", "keydown", "pointerdown", "submit"] as const

type Interaction = NonNullable<BrowserErrorPayload["last_interaction"]>

let lastInteraction: Interaction | undefined
let installed = false

export function installRecoverableErrorInteractionCapture() {
  if (installed) return
  installed = true
  TRACKED_EVENTS.forEach((type) => document.addEventListener(type, captureInteraction, true))
}

export function resetRecoverableErrorDiagnosticsForTest() {
  TRACKED_EVENTS.forEach((type) => document.removeEventListener(type, captureInteraction, true))
  lastInteraction = undefined
  installed = false
}

function captureInteraction(event: Event) {
  const target = event.target instanceof Element ? semanticTarget(event.target) : undefined
  lastInteraction = {
    event_type: event.type,
    timestamp: new Date().toISOString(),
    pathname: safePathname(window.location.pathname),
    ...(target ? { target } : {})
  }
}

export function recentInteraction(now = Date.now()): Interaction | undefined {
  if (!lastInteraction) return undefined
  const age = now - Date.parse(lastInteraction.timestamp)
  return age >= 0 && age <= INTERACTION_MAX_AGE_MS ? lastInteraction : undefined
}

export function semanticTarget(element: Element): Interaction["target"] {
  const semantic = element.closest("[data-testid], [role], button, input, select, textarea, a") || element
  const tag = semantic.tagName.toLowerCase()
  const role = boundedAttribute(semantic.getAttribute("role"))
  const testId = boundedAttribute(semantic.getAttribute("data-testid"))
  const controlType = semantic instanceof HTMLInputElement || semantic instanceof HTMLButtonElement ? boundedAttribute(semantic.type) : undefined

  return {
    tag,
    ...(role ? { role } : {}),
    ...(testId ? { test_id: testId } : {}),
    ...(controlType ? { control_type: controlType } : {})
  }
}

export function nearbyResourceTimings(now = performance.now()): NonNullable<BrowserErrorPayload["resource_timings"]> {
  return performance
    .getEntriesByType("resource")
    .filter((entry): entry is PerformanceResourceTiming => "initiatorType" in entry)
    .filter((entry) => entry.initiatorType === "script" || entry.initiatorType === "link" || /\.(?:js|css)(?:[?#]|$)/i.test(entry.name))
    .filter((entry) => {
      return entry.startTime <= now && entry.startTime >= now - RESOURCE_LOOKBACK_MS
    })
    .sort((left, right) => right.startTime - left.startTime)
    .slice(0, RESOURCE_LIMIT)
    .map((entry) => ({
      name: safeResourceName(entry.name),
      initiator_type: entry.initiatorType,
      start_time_ms: Math.round(entry.startTime),
      duration_ms: Math.round(entry.duration),
      transfer_size: entry.transferSize,
      encoded_body_size: entry.encodedBodySize
    }))
}

export function buildRecoverableErrorPayload(error: unknown, errorInfo: { componentStack?: string | null }): BrowserErrorPayload {
  const normalized = error instanceof Error ? error : new Error(String(error))
  const componentStack = errorInfo.componentStack?.trim() || undefined
  return buildBrowserErrorPayload(normalized, {
    boundary: "react_recoverable",
    componentStack,
    componentStackUnavailableReason: componentStack ? undefined : "React did not supply a component stack",
    correlationId: newCorrelationId(),
    errorCause: serializeErrorCause(normalized.cause),
    fingerprint: computeBrowserErrorFingerprint(normalized),
    lastInteraction: recentInteraction(),
    recoverable: true,
    resourceTimings: nearbyResourceTimings()
  })
}

export function reportRecoverableError(error: unknown, errorInfo: { componentStack?: string | null }) {
  void recordBrowserError(buildRecoverableErrorPayload(error, errorInfo)).catch(() => undefined)
}

export function serializeErrorCause(cause: unknown): BrowserErrorPayload["error_cause"] {
  if (cause instanceof Error) {
    return {
      name: cause.name.slice(0, 100),
      message: scrubBrowserErrorText(cause.message).slice(0, 500),
      stack: scrubBrowserErrorText(cause.stack || "").slice(0, 2_000)
    }
  }
  return cause == null ? undefined : { name: "NonError", message: "Non-Error cause unavailable" }
}

export function newCorrelationId(): string {
  return globalThis.crypto?.randomUUID?.() || `recoverable-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
}

function safeResourceName(value: string): string {
  try {
    const url = new URL(value, window.location.origin)
    return url.origin === window.location.origin ? `${url.origin}${safePathname(url.pathname)}` : `${url.origin}/[cross-origin-resource]`
  } catch {
    return "[unavailable-resource]"
  }
}

function safePathname(path: string): string {
  return path
    .replace(/(\/passwords\/)[^/?#]+(\/edit\b)/gi, "$1[FILTERED]$2")
    .replace(/(\/chats\/shared\/)[^/?#]+/gi, "$1[FILTERED]")
    .slice(0, 500)
}

function boundedAttribute(value: string | null): string | undefined {
  return value?.slice(0, TEST_ID_MAX_LENGTH) || undefined
}

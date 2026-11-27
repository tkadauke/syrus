import { getRecentApiRequests, postJson } from "./client"
import { readInitialBootstrap } from "./bootstrap"
import { getRecentErrors } from "../lib/errorRingBuffer"
import { scrubBrowserErrorText } from "../lib/browserErrorRedaction"
import { readReloadBreadcrumb } from "../lib/pageReload"

export { scrubBrowserErrorText } from "../lib/browserErrorRedaction"

const REDACTED = "[FILTERED]"
const SENSITIVE_ROUTE_PARAM_KEYS = new Set(["token"])

export type BrowserErrorPayload = {
  occurred_at: string
  app_revision: string | null
  fingerprint: string
  name: string
  message: string
  stack?: string
  component_stack?: string
  component_stack_unavailable_reason?: string
  error_cause?: { name: string; message: string; stack?: string }
  url: string
  path: string
  route_id?: string
  route_params?: Record<string, unknown>
  trace_id?: string
  correlation_id?: string
  recoverable?: boolean
  last_interaction?: {
    event_type: string
    timestamp: string
    pathname: string
    target?: { tag: string; role?: string; test_id?: string; control_type?: string }
  }
  resource_timings?: Array<{
    name: string
    initiator_type: string
    start_time_ms: number
    duration_ms: number
    transfer_size: number
    encoded_body_size: number
  }>
  user_agent: string
  viewport: Record<string, unknown>
  feature_flags: Record<string, boolean>
  recent_api_requests: Array<Record<string, unknown>>
  recent_errors: Array<Record<string, unknown>>
  metadata: Record<string, unknown>
}

export type HandledErrorMetadata = {
  surface: string
  operation: string
  stage: string
  recoverability: "retryable" | "non_retryable" | "unknown"
  diagnostics?: Record<string, boolean | number | string>
}

export type BrowserErrorResponse = {
  id: number
  fingerprint: string
  occurrence_count: number
}

export function recordBrowserError(payload: BrowserErrorPayload) {
  return postJson<BrowserErrorResponse>("/api/v1/app/browser_errors", { browser_error: payload })
}

export function buildBrowserErrorPayload(
  error: Error,
  options: {
    componentStack?: string
    componentStackUnavailableReason?: string
    correlationId?: string
    errorCause?: BrowserErrorPayload["error_cause"]
    fingerprint: string
    boundary: string
    lastInteraction?: BrowserErrorPayload["last_interaction"]
    recoverable?: boolean
    resourceTimings?: BrowserErrorPayload["resource_timings"]
    handledError?: HandledErrorMetadata
  }
): BrowserErrorPayload {
  const bootstrap = readInitialBootstrap()
  const route = browserErrorRouteContext(window.location.pathname)
  const safeLocation = browserErrorSafeLocation(window.location)
  return {
    occurred_at: new Date().toISOString(),
    app_revision: bootstrap?.app?.revision ?? null,
    fingerprint: options.fingerprint,
    name: scrubBrowserErrorText(error.name || "Error"),
    message: scrubBrowserErrorText(error.message || "Unknown browser error"),
    stack: error.stack ? scrubBrowserErrorText(error.stack) : undefined,
    component_stack: options.componentStack,
    component_stack_unavailable_reason: options.componentStackUnavailableReason,
    error_cause: options.errorCause,
    url: safeLocation.url,
    path: safeLocation.path,
    route_id: route.route_id,
    route_params: route.route_params,
    correlation_id: options.correlationId,
    recoverable: options.recoverable,
    last_interaction: options.lastInteraction,
    resource_timings: options.resourceTimings,
    user_agent: navigator.userAgent,
    viewport: {
      width: window.innerWidth,
      height: window.innerHeight,
      device_pixel_ratio: window.devicePixelRatio
    },
    feature_flags: bootstrap?.feature_flags ?? {},
    recent_api_requests: getRecentApiRequests(),
    recent_errors: getRecentErrors(),
    metadata: {
      boundary: options.boundary,
      history_length: window.history.length,
      visibility_state: document.visibilityState,
      previous_reload: readReloadBreadcrumb(),
      navigation_type: (performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming | undefined)?.type ?? null,
      ...(options.handledError ? { handled_error: options.handledError } : {})
    }
  }
}

function browserErrorSafeLocation(location: Location): { url: string; path: string } {
  const path = scrubSensitivePathSegments(location.pathname)
  return {
    url: `${location.origin}${path}`,
    path
  }
}

function scrubSensitivePathSegments(path: string): string {
  return path.replace(/(\/passwords\/)[^/?#]+(\/edit\b)/g, `$1${REDACTED}$2`).replace(/(\/chats\/shared\/)[^/?#]+/g, `$1${REDACTED}`)
}

export function browserErrorRouteContext(pathname: string): { route_id?: string; route_params?: Record<string, string> } {
  const routes: Array<{ id: string; pattern: RegExp; keys: string[] }> = [
    { id: "admin.backend_exceptions", pattern: /^\/admin\/backend_exceptions\/?$/, keys: [] },
    { id: "admin.browser_errors", pattern: /^\/admin\/browser_errors\/?$/, keys: [] },
    { id: "admin.performance", pattern: /^\/admin\/performance\/?$/, keys: [] },
    { id: "admin.reconciler_activity", pattern: /^\/admin\/reconciler_activity\/?$/, keys: [] },
    { id: "admin.activity", pattern: /^\/admin\/activity\/?$/, keys: [] },
    { id: "admin.queue", pattern: /^\/admin\/queue(?:\/([^/]+))?\/?$/, keys: ["tab"] },
    { id: "chat.show", pattern: /^\/chats\/([^/]+)\/?$/, keys: ["id"] },
    { id: "chat.shared", pattern: /^\/chats\/shared\/([^/]+)\/?$/, keys: ["token"] },
    { id: "password.reset", pattern: /^\/passwords\/([^/]+)\/edit\/?$/, keys: ["token"] },
    { id: "job.source", pattern: /^\/jobs\/([^/]+)\/source\/?$/, keys: ["id"] },
    { id: "job.show", pattern: /^\/jobs\/([^/]+)\/?$/, keys: ["id"] },
    { id: "epic.show", pattern: /^\/epics\/([^/]+)\/?$/, keys: ["id"] },
    { id: "repository.insights", pattern: /^\/repositories\/([^/]+)\/insights\/?$/, keys: ["id"] },
    { id: "repository.show", pattern: /^\/repositories\/([^/]+)\/?$/, keys: ["id"] },
    { id: "dashboard", pattern: /^\/dashboard(?:\/([^/]+))?\/?$/, keys: ["subject"] },
    { id: "settings.agent", pattern: /^\/settings\/agent\/?$/, keys: [] },
    { id: "settings.preferences", pattern: /^\/settings\/preferences\/?$/, keys: [] },
    { id: "settings.profile", pattern: /^\/(?:settings|profile)\/?$/, keys: [] }
  ]

  for (const route of routes) {
    const match = pathname.match(route.pattern)
    if (!match) continue
    const route_params = route.keys.reduce<Record<string, string>>((params, key, index) => {
      const value = match[index + 1]
      if (value) params[key] = SENSITIVE_ROUTE_PARAM_KEYS.has(key) ? REDACTED : decodeURIComponent(value)
      return params
    }, {})
    return { route_id: route.id, route_params }
  }

  return {}
}

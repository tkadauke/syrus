import { getRecentApiRequests, postJson } from "./client"
import { readInitialBootstrap } from "./bootstrap"
import { getRecentErrors } from "../lib/errorRingBuffer"

export type BrowserErrorPayload = {
  occurred_at: string
  app_revision: string | null
  fingerprint: string
  name: string
  message: string
  stack?: string
  component_stack?: string
  url: string
  path: string
  route_id?: string
  route_params?: Record<string, unknown>
  trace_id?: string
  user_agent: string
  viewport: Record<string, unknown>
  feature_flags: Record<string, boolean>
  recent_api_requests: Array<Record<string, unknown>>
  recent_errors: Array<Record<string, unknown>>
  metadata: Record<string, unknown>
}

export type BrowserErrorResponse = {
  id: number
  fingerprint: string
}

export function recordBrowserError(payload: BrowserErrorPayload) {
  return postJson<BrowserErrorResponse>("/api/v1/app/browser_errors", { browser_error: payload })
}

export function buildBrowserErrorPayload(error: Error, options: { componentStack?: string; fingerprint: string; boundary: string }): BrowserErrorPayload {
  const bootstrap = readInitialBootstrap()
  const route = browserErrorRouteContext(window.location.pathname)
  return {
    occurred_at: new Date().toISOString(),
    app_revision: bootstrap?.app?.revision ?? null,
    fingerprint: options.fingerprint,
    name: error.name || "Error",
    message: error.message || "Unknown browser error",
    stack: error.stack,
    component_stack: options.componentStack,
    url: window.location.href,
    path: `${window.location.pathname}${window.location.search}`,
    route_id: route.route_id,
    route_params: route.route_params,
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
      visibility_state: document.visibilityState
    }
  }
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
      if (value) params[key] = decodeURIComponent(value)
      return params
    }, {})
    return { route_id: route.id, route_params }
  }

  return {}
}

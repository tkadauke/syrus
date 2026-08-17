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
      visibility_state: document.visibilityState
    }
  }
}

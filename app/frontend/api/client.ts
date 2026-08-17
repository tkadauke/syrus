import { reloadPage } from "../lib/pageReload"

export type ApiErrorPayload = {
  error?: {
    code?: string
    message?: string
  }
}

export class ApiError extends Error {
  readonly status: number
  readonly code?: string

  constructor(message: string, options: { status: number; code?: string }) {
    super(message)
    this.name = "ApiError"
    this.status = options.status
    this.code = options.code
  }
}

const REVISION_HEADER = "X-Syrus-Revision"
const RELOAD_STORAGE_KEY = "syrus:revision-reload"
const MAX_RECENT_API_REQUESTS = 20
let embeddedRevision: string | null | undefined

export type RecentApiRequest = {
  path: string
  requestId: string | null
  status: number
  durationMs: number
  at: string
}

const recentApiRequests: RecentApiRequest[] = []

export async function getJson<T>(path: string, options: { signal?: AbortSignal } = {}): Promise<T> {
  const startedAt = performanceNow()
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json"
    },
    signal: options.signal
  })
  recordApiRequest(path, response, performanceNow() - startedAt)
  reloadIfBackendRevisionChanged(response)

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

export type JsonResponseMeta = {
  path: string
  requestId: string | null
  status: number
  durationMs: number
}

export async function getJsonWithMeta<T>(path: string, options: { signal?: AbortSignal } = {}): Promise<{ data: T; meta: JsonResponseMeta }> {
  const startedAt = performanceNow()
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json"
    },
    signal: options.signal
  })
  const meta = responseMeta(path, response, startedAt)
  recordApiRequest(path, response, meta.durationMs)
  reloadIfBackendRevisionChanged(response)

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return { data: undefined as T, meta }

  return { data: await response.json() as T, meta }
}

export async function postJson<T>(path: string, body?: unknown): Promise<T> {
  return writeJson<T>(path, "POST", body)
}

export async function patchJson<T>(path: string, body?: unknown): Promise<T> {
  return writeJson<T>(path, "PATCH", body)
}

export async function deleteJson<T>(path: string): Promise<T> {
  return writeJson<T>(path, "DELETE")
}

export async function postForm<T>(path: string, body: FormData): Promise<T> {
  const startedAt = performanceNow()
  const headers: Record<string, string> = {
    Accept: "application/json"
  }
  const csrfToken = document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content

  if (csrfToken) {
    headers["X-CSRF-Token"] = csrfToken
  }

  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers,
    body
  })
  recordApiRequest(path, response, performanceNow() - startedAt)
  reloadIfBackendRevisionChanged(response)

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

async function writeJson<T>(path: string, method: "POST" | "PATCH" | "DELETE", body?: unknown): Promise<T> {
  const startedAt = performanceNow()
  const headers: Record<string, string> = {
    Accept: "application/json"
  }
  const csrfToken = document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content

  if (csrfToken) {
    headers["X-CSRF-Token"] = csrfToken
  }
  if (body !== undefined) {
    headers["Content-Type"] = "application/json"
  }

  const response = await fetch(path, {
    method,
    credentials: "same-origin",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  })
  recordApiRequest(path, response, performanceNow() - startedAt)
  reloadIfBackendRevisionChanged(response)

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

async function readErrorPayload(response: Response): Promise<ApiErrorPayload> {
  try {
    return (await response.json()) as ApiErrorPayload
  } catch (_error) {
    return {}
  }
}

function responseMeta(path: string, response: Response, startedAt: number): JsonResponseMeta {
  return {
    path,
    requestId: response.headers.get("X-Request-Id") || response.headers.get("X-Request-ID"),
    status: response.status,
    durationMs: Math.max(0, performanceNow() - startedAt)
  }
}

function performanceNow(): number {
  return typeof performance !== "undefined" && typeof performance.now === "function" ? performance.now() : Date.now()
}

function recordApiRequest(path: string, response: Response, durationMs: number | null): void {
  recentApiRequests.push({
    path,
    requestId: response.headers.get("X-Request-Id") || response.headers.get("X-Request-ID"),
    status: response.status,
    durationMs: durationMs == null ? 0 : Math.round(durationMs * 10) / 10,
    at: new Date().toISOString()
  })
  if (recentApiRequests.length > MAX_RECENT_API_REQUESTS) recentApiRequests.shift()
}

export function getRecentApiRequests(): RecentApiRequest[] {
  return [...recentApiRequests]
}

export function _clearRecentApiRequestsForTest(): void {
  recentApiRequests.length = 0
}

function reloadIfBackendRevisionChanged(response: Response): void {
  const backendRevision = response.headers.get(REVISION_HEADER)
  if (!backendRevision || backendRevision === "dev") return

  const frontendRevision = initialEmbeddedRevision()
  if (!frontendRevision || frontendRevision === "dev" || frontendRevision === backendRevision) return
  if (typeof window === "undefined") return

  const key = `${frontendRevision}->${backendRevision}`
  try {
    if (window.sessionStorage.getItem(RELOAD_STORAGE_KEY) === key) return
    window.sessionStorage.setItem(RELOAD_STORAGE_KEY, key)
  } catch {
    // Storage can be unavailable in private or locked-down contexts. Reloading
    // once is still better than keeping an old module graph alive indefinitely.
  }

  reloadPage()
}

function initialEmbeddedRevision(): string | null {
  if (embeddedRevision !== undefined) return embeddedRevision
  embeddedRevision = null

  const element = typeof document === "undefined" ? null : document.getElementById("syrus-bootstrap-data")
  if (!element?.textContent) return embeddedRevision

  try {
    const payload = JSON.parse(element.textContent) as { app?: { revision?: unknown } }
    embeddedRevision = typeof payload.app?.revision === "string" ? payload.app.revision : null
  } catch {
    embeddedRevision = null
  }

  return embeddedRevision
}

export function resetRevisionReloadStateForTests(): void {
  embeddedRevision = undefined
}

import type { WebContents } from "electron"
import type { Credentials } from "./credentialsStore.js"

// Auto-provisions the menu-bar Bearer token from the signed-in webview
// session so users never paste a token by hand. The script runs inside the
// page, riding its session cookie AND its meta[name=csrf-token] — no cookie
// or CSRF plumbing in the main process. A 403 (non-admin on a remote
// instance) falls back silently to the manual paste flow in Preferences.
const PROVISION_SCRIPT = `
  (async () => {
    try {
      const status = await fetch("/api/v1/app/auth/status", { headers: { Accept: "application/json" } })
      if (!status.ok) return { state: "signed_out" }
      const statusPayload = await status.json()
      if (!statusPayload || statusPayload.authenticated !== true) return { state: "signed_out" }

      const meta = document.querySelector('meta[name="csrf-token"]')
      const csrf = meta ? meta.getAttribute("content") : null
      if (!csrf) return { state: "no_csrf" }

      const response = await fetch("/api/v1/app/desktop/api_token", {
        method: "POST",
        headers: { "X-CSRF-Token": csrf, Accept: "application/json" }
      })
      if (response.status === 403) return { state: "forbidden" }
      if (!response.ok) return { state: "error" }

      const payload = await response.json()
      return { state: "ok", apiToken: payload.api_token }
    } catch {
      return { state: "error" }
    }
  })()
`

type ProvisionResult =
  | "already-configured"
  | "suppressed"
  | "different-instance"
  | "provisioned"
  | "signed_out"
  | "no_csrf"
  | "forbidden"
  | "error"

type ProvisionDeps = {
  getCachedCredentials: () => Credentials | null
  autoProvisioningAllowed: () => boolean
  // main.ts's saveCredentials: validates against the server, writes
  // ~/.syrus/credentials, and starts the notification cable.
  saveCredentials: (credentials: Credentials) => Promise<unknown>
  // True when the stored token has been rejected (401) by its own instance —
  // e.g. the local backend's database was rebuilt and the token on disk
  // predates it. Suspect same-instance credentials must NOT block
  // re-provisioning, or the app can never heal itself.
  credentialsSuspect?: (credentials: Credentials) => boolean
}

const normalizeUrl = (url: string) => url.trim().replace(/\/+$/, "")

const credentialsMatch = (left: Credentials | null, right: Credentials | null) =>
  left?.url.trim() === right?.url.trim() && left?.token.trim() === right?.token.trim()

// In-page navigations can fire in bursts; one attempt at a time is plenty.
let attemptInFlight = false

// A 403 is terminal for this instance (non-admin user): without the latch
// every SPA route change would re-POST and 403 again for the whole session.
let forbiddenInstanceUrl: string | null = null

// executeJavaScript's promise can simply never settle when the frame is torn
// down mid-flight (navigation, window close). Unbounded, that would wedge
// attemptInFlight and silently disable provisioning for the rest of the run.
const EXECUTE_TIMEOUT_MS = 15_000
const EXECUTE_TIMED_OUT = Symbol("execute-timed-out")

export const maybeProvisionDesktopToken = async (
  webContents: WebContents,
  serverUrl: string,
  deps: ProvisionDeps
): Promise<ProvisionResult> => {
  const normalized = normalizeUrl(serverUrl)
  const cached = deps.getCachedCredentials()
  if (!deps.autoProvisioningAllowed()) {
    return "suppressed"
  }
  if (cached) {
    // ~/.syrus/credentials is shared with the syrus CLI. Credentials
    // configured for a DIFFERENT instance must never be overwritten by
    // auto-provisioning — that would silently retarget the user's CLI.
    if (normalizeUrl(cached.url) !== normalized) {
      return "different-instance"
    }

    // Same instance: healthy credentials stay untouched, but a token the
    // instance itself has rejected (backend DB rebuilt, token revoked) falls
    // through and gets re-minted from the signed-in web session.
    if (!deps.credentialsSuspect?.(cached)) {
      return "already-configured"
    }
  }

  if (normalized === forbiddenInstanceUrl) {
    return "forbidden"
  }

  if (attemptInFlight) {
    return "error"
  }

  attemptInFlight = true
  let result: { state?: string; apiToken?: unknown }
  try {
    const execution = webContents.executeJavaScript(PROVISION_SCRIPT, true)
    // The race may abandon the execution promise; a later rejection must not
    // surface as an unhandled rejection.
    execution.catch(() => {})
    let timeoutTimer: NodeJS.Timeout | undefined
    const raced = await Promise.race([
      execution,
      new Promise((resolve) => {
        timeoutTimer = setTimeout(() => resolve(EXECUTE_TIMED_OUT), EXECUTE_TIMEOUT_MS)
      })
    ]).finally(() => clearTimeout(timeoutTimer))

    if (raced === EXECUTE_TIMED_OUT) {
      return "error"
    }

    result = raced as { state?: string; apiToken?: unknown }
  } catch {
    return "error"
  } finally {
    attemptInFlight = false
  }

  if (result?.state === "ok" && typeof result.apiToken === "string" && result.apiToken !== "") {
    // The page script can take up to 15 seconds. A manual save or explicit
    // sign-out during that window owns the resulting state; never overwrite
    // it with the token minted by the now-stale attempt.
    if (!deps.autoProvisioningAllowed() || !credentialsMatch(cached, deps.getCachedCredentials())) {
      return "suppressed"
    }

    try {
      await deps.saveCredentials({ url: normalized, token: result.apiToken })
      return "provisioned"
    } catch {
      return "error"
    }
  }

  const state = result?.state
  if (state === "forbidden") {
    forbiddenInstanceUrl = normalized
    return state
  }

  if (state === "signed_out" || state === "no_csrf") {
    return state
  }

  return "error"
}

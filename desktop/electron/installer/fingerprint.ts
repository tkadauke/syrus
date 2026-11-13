// "Is this URL a Syrus instance?" without needing credentials: the auth
// status endpoint is unauthenticated JSON on every Syrus install. Failure
// messages are classified so the connect form can say what to actually do.
import { ApiVersionError, readApiJson } from "../apiVersion.js"

// Electron-free on purpose — global fetch only — so the classification is
// unit-testable from vitest (desktop/src/fingerprint.test.ts).
export const fingerprintSyrus = async (url: string) => {
  let response: Response
  try {
    response = await fetch(`${url}/api/v1/app/auth/status`, { signal: AbortSignal.timeout(5_000) })
  } catch {
    // Suggest the default port only when none was given — the classic
    // forgot-the-port case. When the user typed a port (or the address
    // carries the assumed :3000 already), lecturing about :3000 is noise.
    const portless = !/:\d+$/.test(url)
    throw new Error(
      `Nothing answered at ${url}. Check that Syrus is running there and the address is right.` +
        (portless ? " If your instance serves on a specific port, include it — local installs use :3000." : "")
    )
  }

  // Rails host authorization rejects hostnames it doesn't know — the fix is
  // on the server, so say so instead of a generic "doesn't look like Syrus".
  if (response.status === 403) {
    throw new Error(
      `The server at ${url} refused this hostname. Add it to SYRUS_ALLOWED_HOSTS in the instance's .env (comma-separated), restart Syrus, and try again.`
    )
  }

  if (!response.ok) {
    throw new Error(`Something answered at ${url}, but it doesn't look like a Syrus instance.`)
  }

  try {
    const payload = await readApiJson<{ authenticated?: unknown }>(response)
    if (typeof payload.authenticated !== "boolean") {
      throw new Error("shape")
    }
  } catch (error) {
    if (error instanceof ApiVersionError) throw error
    throw new Error(`Something answered at ${url}, but it doesn't look like a Syrus instance.`)
  }
}

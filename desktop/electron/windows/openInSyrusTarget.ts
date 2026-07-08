// The configured instance URL's web origin, or null when no instance is
// configured (or the stored URL is unparseable). This is THE origin
// authority for renderer-facing trust decisions: the Open-in-Syrus target
// resolver below and main.ts's shell:* IPC sender validation both compare
// against it, so "same instance" means the same thing everywhere.
export const resolveInstanceOrigin = (serverUrl: string): string | null => {
  const normalizedServerUrl = serverUrl.trim().replace(/\/+$/, "")
  if (normalizedServerUrl === "") {
    return null
  }

  try {
    return new URL(normalizedServerUrl).origin
  } catch {
    return null
  }
}

// Resolves a tray "Open in Syrus" target against the configured instance
// URL. Accepts an instance-relative path ("/jobs/12", with query/fragment)
// or a full URL, and returns the absolute URL to load in the web-app
// window — or null when there is nothing safe to navigate to: no instance
// configured, an unparseable target, or a CROSS-ORIGIN target (the app
// window must never be steered to a foreign origin by renderer input).
export const resolveOpenInSyrusTarget = (serverUrl: string, target: string): string | null => {
  const normalizedServerUrl = serverUrl.trim().replace(/\/+$/, "")
  const instanceOrigin = resolveInstanceOrigin(serverUrl)
  if (instanceOrigin === null || target.trim() === "") {
    return null
  }

  let destination: URL
  try {
    destination = new URL(target, `${normalizedServerUrl}/`)
  } catch {
    return null
  }

  if (destination.origin !== instanceOrigin) {
    return null
  }

  return destination.toString()
}

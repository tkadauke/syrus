import {
  BrowserWindow,
  desktopCapturer,
  dialog,
  screen,
  session,
  systemPreferences,
  type MessageBoxOptions,
  type WebContents
} from "electron"

// Screen + microphone capture for the walkthrough recorder.
//
// getDisplayMedia REJECTS in Electron unless a display-media handler is
// registered — the web app's "Record a walkthrough" would silently fail in the
// desktop shell without this, while working in a plain Chrome tab. The mic
// rides along as a separate getUserMedia(audio) call in the renderer; macOS
// only hands back a real (non-silent) track when the app has the
// com.apple.security.device.audio-input entitlement + NSMicrophoneUsageDescription
// (see build/entitlements.mac.plist and electron-builder.yml) AND the OS-level
// microphone permission is granted — which we pre-warm below.

export type TrustedCaptureContext = {
  webContents: WebContents | null
  origin: string | null
}

type TrustedCaptureContextProvider = () => TrustedCaptureContext

const ALLOWED_PERMISSIONS = new Set(["media", "display-capture", "clipboard-sanitized-write"])

const matchesOrigin = (url: string, expectedOrigin: string | null): boolean => {
  if (!expectedOrigin) return false

  try {
    return new URL(url).origin === expectedOrigin
  } catch {
    return false
  }
}

// Permission handlers belong to the default session, which is shared by every
// desktop window. Keep the grant narrower than that session: only the current
// Syrus web-app window, its configured origin, its top frame, and the three
// permissions the shell actually needs may pass.
export const registerMediaPermissionHandlers = (trustedContext: TrustedCaptureContextProvider) => {
  const activeSession = session.defaultSession
  activeSession.setPermissionRequestHandler((webContents, permission, callback, details) => {
    const trusted = trustedContext()
    callback(
      trusted.webContents !== null &&
        webContents === trusted.webContents &&
        ALLOWED_PERMISSIONS.has(permission) &&
        details.isMainFrame &&
        matchesOrigin(details.requestingUrl, trusted.origin)
    )
  })
  activeSession.setPermissionCheckHandler((webContents, permission, requestingOrigin, details) => {
    const trusted = trustedContext()
    return (
      trusted.webContents !== null &&
      webContents === trusted.webContents &&
      ALLOWED_PERMISSIONS.has(permission) &&
      details.isMainFrame &&
      matchesOrigin(requestingOrigin, trusted.origin)
    )
  })
}

export const prewarmMicrophonePermission = async (): Promise<boolean> => {
  if (process.platform !== "darwin") return true

  try {
    return await systemPreferences.askForMediaAccess("microphone")
  } catch {
    return false
  }
}

// The screen the user is actively working on (the cursor's display), so a
// multi-monitor walkthrough records the monitor they're demonstrating on;
// fall back to the first source if the match can't be resolved.
const pickScreenSource = (sources: Electron.DesktopCapturerSource[]): Electron.DesktopCapturerSource => {
  try {
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint())
    const match = sources.find((source) => String(source.display_id) === String(display.id))
    if (match) return match
  } catch {
    // screen APIs unavailable — fall through to the first source
  }
  return sources[0]
}

export const registerScreenCaptureHandler = (trustedContext: TrustedCaptureContextProvider) => {
  session.defaultSession.setDisplayMediaRequestHandler(
    async (request, callback) => {
      const trusted = trustedContext()
      if (
        !trusted.webContents ||
        request.frame !== trusted.webContents.mainFrame ||
        !matchesOrigin(request.securityOrigin, trusted.origin)
      ) {
        callback({})
        return
      }

      const parent = BrowserWindow.fromWebContents(trusted.webContents)
      const confirmationOptions: MessageBoxOptions = {
        type: "question",
        buttons: ["Share screen", "Cancel"],
        defaultId: 1,
        cancelId: 1,
        title: "Share your screen?",
        message: "Syrus wants to record your entire screen.",
        detail: "Everything visible on the selected display may appear in the walkthrough."
      }
      let confirmed = false
      try {
        const confirmation = parent
          ? await dialog.showMessageBox(parent, confirmationOptions)
          : await dialog.showMessageBox(confirmationOptions)
        confirmed = confirmation.response === 0
      } catch {
        confirmed = false
      }
      if (!confirmed) {
        callback({})
        return
      }

      // Pre-warm the microphone TCC prompt HERE (recording is starting), so the
      // renderer's getUserMedia(audio) fired right after captures real narration
      // instead of a silent track. Best-effort + macOS-only.
      await prewarmMicrophonePermission()

      try {
        const sources = await desktopCapturer.getSources({ types: ["screen"] })
        if (sources.length === 0) {
          callback({})
          return
        }
        callback({ video: pickScreenSource(sources) })
      } catch {
        callback({})
      }
    },
    // useSystemPicker is intentionally OFF: a walkthrough always captures the
    // WHOLE screen, never a single window or tab. The red-pen annotation overlay
    // is a separate always-on-top window that only gets composited into a
    // full-SCREEN capture; the native picker let users pick a window and
    // silently dropped every mark (the exact bug users hit). Forcing full-screen
    // guarantees the annotations record. (macOS Screen Recording permission is
    // the same TCC grant the picker used, so returning users keep it.)
    { useSystemPicker: false }
  )
}

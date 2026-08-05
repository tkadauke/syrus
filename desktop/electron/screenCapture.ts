import { desktopCapturer, screen, session, systemPreferences } from "electron"

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

// Approve the renderer's permission requests/checks so getUserMedia(audio) and
// getDisplayMedia aren't denied at the Electron layer. This is a trusted
// first-party shell loading only Syrus's own web app; without any handler
// Electron already approves these by default, so granting explicitly is not a
// widening of trust — it just makes the media surface deterministic across
// platforms (and macOS TCC still gates the actual mic/screen access).
export const registerMediaPermissionHandlers = () => {
  const activeSession = session.defaultSession
  activeSession.setPermissionRequestHandler((_webContents, _permission, callback) => callback(true))
  activeSession.setPermissionCheckHandler(() => true)
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

export const registerScreenCaptureHandler = () => {
  session.defaultSession.setDisplayMediaRequestHandler(
    async (_request, callback) => {
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

require "rails_helper"

# The desktop shell must support the web app's walkthrough recorder:
# getDisplayMedia REJECTS in Electron unless a display-media handler is
# registered on the session the web-app window uses (the default session), and
# getUserMedia(audio) can be denied at the Electron layer without a permission
# handler. The recorder also needs the WHOLE screen (never a window) so the
# red-pen annotation overlay is composited into the capture, plus the macOS
# microphone entitlement so narration isn't a silent track.
RSpec.describe "desktop screen capture" do
  def read(path)
    File.read(Rails.root.join("desktop", path))
  end

  it "registers a display-media handler that FORCES full-screen capture" do
    capture = read("electron/screenCapture.ts")
    expect(capture).to include("session.defaultSession.setDisplayMediaRequestHandler")
    # useSystemPicker OFF: a walkthrough always captures the whole screen so the
    # annotation overlay records; the native picker let users pick a window and
    # silently dropped every mark.
    expect(capture).to include("useSystemPicker: false")
    expect(capture).to match(/desktopCapturer\s*\.getSources\(\{ types: \["screen"\] \}\)/)
    # A capture failure must decline the request, not hang the promise.
    expect(capture).to include("callback({})")

    main = read("electron/main.ts")
    expect(main).to include("registerScreenCaptureHandler()")
  end

  it "grants the renderer's media permissions and pre-warms the mic on macOS" do
    capture = read("electron/screenCapture.ts")
    expect(capture).to include("setPermissionRequestHandler")
    expect(capture).to include("setPermissionCheckHandler")
    # Pre-warm the microphone TCC prompt when recording starts.
    expect(capture).to include("prewarmMicrophonePermission")
    expect(capture).to include("systemPreferences.askForMediaAccess(\"microphone\")")

    main = read("electron/main.ts")
    expect(main).to include("registerMediaPermissionHandlers()")
  end

  it "exposes a standalone dictation microphone prewarm bridge" do
    main = read("electron/main.ts")
    expect(main).to include("dictation:prewarm-microphone")
    expect(main).to include("shellSenderAllowed(event, \"dictation:prewarm-microphone\")")

    preload = read("electron/windows/webAppPreload.cts")
    expect(preload).to include("dictation")
    expect(preload).to include("prewarmMicrophone")
    expect(preload).to include("ipcRenderer.invoke(\"dictation:prewarm-microphone\")")

    compose = File.read(Rails.root.join("app/frontend/routes/chat/Compose.tsx"))
    expect(compose).to include("syrusShellBridge()?.dictation?.prewarmMicrophone?.()")
  end

  it "declares the macOS microphone entitlement + usage description" do
    entitlements = read("build/entitlements.mac.plist")
    expect(entitlements).to include("com.apple.security.device.audio-input")

    builder = read("electron-builder.yml")
    expect(builder).to include("NSMicrophoneUsageDescription")
  end
end

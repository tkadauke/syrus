# frozen_string_literal: true

require "spec_helper"

# EPIC-275's second Job: the Electron main process's own native-notification
# dispatch (desktop/electron/nativeNotifications.ts's dispatchNativeNotification,
# wired to the AppUserChannel WebSocket subscription in main.ts) used to fire
# unconditionally for every notification_created event, even while the shared
# frontend (app/frontend/lib/nativeNotifications.ts, loaded into webAppWindow
# too) dispatches the SAME notification via the standard Web Notification API.
# Main's dispatch is now a fallback for "app running, no live window handling
# it" — never a second guaranteed path. This spec statically parses main.ts
# and webAppPreload.cts (same style as shell_notice_bridge_spec.rb) to pin
# the gating contract in place, since desktop/electron/*.ts isn't covered by
# the Vitest suite (only desktop/src/**).
RSpec.describe "desktop native-notification fallback gating" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:preload) { read("electron/windows/webAppPreload.cts") }
  let(:main) { read("electron/main.ts") }

  it "exposes a notifications.reportLive bridge member on window.syrusShell" do
    expect(preload).to match(/notifications: \{\s*\n\s*reportLive: \(live: boolean\) => \{/)
    expect(preload).to include('void ipcRenderer.invoke("shell:notifications-live", live)')
  end

  it "registers a sender-validated shell:notifications-live handler in main" do
    handler = main[/ipcMain\.handle\("shell:notifications-live"[\s\S]{0,300}/]
    expect(handler).not_to be_nil
    # Same validated-sender pattern as every other shell:* handler: refused
    # (foreign sender) or malformed payloads are treated as "not live" so
    # main keeps dispatching rather than going silently silent.
    expect(handler).to include('if (!shellSenderAllowed(event, "shell:notifications-live")) {')
    expect(handler).to include("webAppNotificationsLive = false")
    expect(handler).to include('webAppNotificationsLive = live === true')
  end

  it "resets the liveness flag when the web-app window closes" do
    on_closed = main[/onClosed: \(\) => \{\s*\n\s*webAppWindow = null[\s\S]{0,400}/]
    expect(on_closed).not_to be_nil
    expect(on_closed).to include("webAppNotificationsLive = false")
  end

  it "requires BOTH reported liveness AND real-time window visibility before treating the web app as handling notifications" do
    helper = main[/const webAppWindowHandlingNotifications = \(\): boolean => \{[\s\S]{0,400}/]
    expect(helper).not_to be_nil
    expect(helper).to include("if (!webAppNotificationsLive) return false")
    expect(helper).to include("if (!window || window.isDestroyed()) return false")
    expect(helper).to include("return window.isVisible() && !window.isMinimized()")
  end

  it "only skips main's own dispatchNativeNotification call when the web app is demonstrably already handling the event" do
    listener = main[/desktopNotificationEvents\.on\(DESKTOP_NOTIFICATION_EVENT, \(event: unknown\) => \{[\s\S]{0,700}/]
    expect(listener).not_to be_nil
    expect(listener).to match(/if \(!webAppWindowHandlingNotifications\(\)\) \{\s*\n\s*dispatchNativeNotification\(event, cachedCredentials\)/)
    # broadcastNotificationEvent (renderer badge/bell update) stays
    # unconditional — only the OS-level native dispatch is gated.
    expect(listener).to match(/\}\s*\n\s*broadcastNotificationEvent\(event\)/)
  end
end

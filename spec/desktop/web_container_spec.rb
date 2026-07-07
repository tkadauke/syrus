# frozen_string_literal: true

require "spec_helper"

# The main window is a web container over the (local or remote) Syrus web
# app. Remote content must never see the IPC bridge, external links must
# leave the app, and losing the backend swaps in an inert status page that
# recovers automatically.
RSpec.describe "desktop web-container window" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:web_app_window) { read("electron/windows/webAppWindow.ts") }
  let(:main_process) { read("electron/main.ts") }
  let(:renderer_entry) { read("src/main.tsx") }
  let(:backend_status) { read("src/BackendStatus.tsx") }

  it "loads remote content fully isolated, with no preload bridge" do
    expect(web_app_window).to include("contextIsolation: true")
    expect(web_app_window).to include("nodeIntegration: false")
    expect(web_app_window).to include("sandbox: true")
    expect(web_app_window).not_to include("preload:")
  end

  it "keeps same-origin navigation in-window and opens everything else externally" do
    expect(web_app_window).to include('window.webContents.on("will-navigate"')
    expect(web_app_window).to include("window.webContents.setWindowOpenHandler")
    expect(web_app_window).to include("decideWindowOpen")
    expect(web_app_window).to include("shell.openExternal")
  end

  it "never allows popups — flows that need a real browser use the syrus_external marker" do
    # POST-carrying popups (form target=_blank) are not special-cased any
    # more: a POST body cannot survive the hand-off to the external browser,
    # so such flows (the GitHub App manifest) run through a same-origin GET
    # bounce page marked syrus_external=1, which the policy routes to the
    # default browser where the user has real logins.
    window_open_policy = read("electron/windows/windowOpenPolicy.ts")
    expect(window_open_policy).to include('searchParams.get("syrus_external") === "1"')
    expect(web_app_window).not_to include('action: "allow"')
    expect(web_app_window).not_to include("postBody")
    expect(web_app_window).not_to include("did-create-window")
  end

  it "marks the web container's user agent so the web app can detect the shell" do
    expect(web_app_window).to include("SyrusDesktop/")
    expect(web_app_window).to include("setUserAgent")
    # The app build rides a second UA token (from the staged manifest) so the
    # web UI's BuildBadge can show which build hosts it. Release builds
    # announce the release version, dev builds the git sha — one token,
    # version-or-sha ("0.0.0" is the dev placeholder, never a release).
    expect(web_app_window).to include("SyrusDesktopBuild/")
    expect(main_process).to include(
      'buildSha: (manifest?.appVersion && manifest.appVersion !== "0.0.0" ? manifest.appVersion : manifest?.appBuild) ?? null'
    )
    # A third token carries the app's build time for the badge's hover
    # tooltip, encoded ISO-8601 BASIC (20260707T143200Z) because colons are
    # not valid in UA product-version tokens — desktopBuiltAt() decodes it.
    expect(web_app_window).to include("SyrusDesktopBuiltAt/")
    expect(web_app_window).to include('.toISOString().slice(0, 19).replace(/[-:]/g, "")')
    expect(main_process).to include("builtAt: manifest?.builtAt ?? null")
    # stage-backend-assets stamps the timestamp the token is derived from.
    # Dev builds stamp the wall clock (staging time IS the build moment);
    # release builds derive it from HEAD's committer date — the same source
    # release.yml / bin/publish-image bake into the backend image as
    # SYRUS_BUILT_AT — normalized to the identical second-precision UTC
    # ISO-8601 form, so the BuildBadge's app and backend tooltips show the
    # IDENTICAL instant on a release.
    stage_script = read("scripts/stage-backend-assets.mjs")
    expect(stage_script).to include("if (!isReleaseBuild) return new Date().toISOString()")
    expect(stage_script).to include('execSync("git show -s --format=%ct HEAD"')
    expect(stage_script).to include('new Date(Number(epochSeconds) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z")')
    expect(stage_script).to include("appVersion: version, appBuild, builtAt")
  end

  it "exposes the context-menu essentials to the left-click popover" do
    expect(main_process).to include('ipcMain.handle("open-syrus"')
    expect(main_process).to include('ipcMain.handle("quit-app"')
    preload = read("electron/preload.cts")
    expect(preload).to include("openSyrusWindow")
    expect(preload).to include("quitApp")
    tray_app = read("src/App.tsx")
    expect(tray_app).to include("TrayActionsBar")
  end

  it "falls back to the status page only for real main-frame failures of the server URL" do
    expect(web_app_window).to include('"did-fail-load"')
    # ERR_ABORTED (-3) is benign (superseded navigation / download) and must
    # not yank a healthy app to the status page.
    expect(web_app_window).to include("if (errorCode === -3 || !isMainFrame || !validatedURL.startsWith(serverOrigin))")
  end

  it "denies renderer-initiated file: navigations" do
    # The old guard carried a file: exemption; the policy must deny all
    # non-web protocols.
    window_open_policy = read("electron/windows/windowOpenPolicy.ts")
    expect(web_app_window).not_to include('target.protocol !== "file:"')
    expect(window_open_policy).to match(/if \(!\["http:", "https:"\]\.includes\(target\.protocol\)\) \{\s*return "deny"/)
  end

  it "gates startup on the single-instance lock so the losing instance runs nothing" do
    expect(main_process).to include("const hasSingleInstanceLock = app.requestSingleInstanceLock(ownInstanceIdentity())")
    when_ready = main_process[/app\.whenReady\(\)\.then\(async \(\) => \{[\s\S]{0,200}/]
    expect(when_ready).to include("if (!hasSingleInstanceLock)")
  end

  it "offers takeover when a different version or bundle launches against a running instance" do
    # Field lesson: a stale copy running off a mounted DMG silently swallowed
    # every newer launch. The launching instance identifies itself via the
    # lock's additionalData; the running instance offers Switch/Keep, and on
    # Switch releases the lock BEFORE launching the new copy (or the new copy
    # loses the lock race against the dying instance — the original trap).
    expect(main_process).to include("decideOnSecondInstance(own, incoming)")
    handler = main_process[/app\.on\("second-instance"[\s\S]{0,1800}/]
    expect(handler).to include("takeoverPrompt(own, incoming")
    expect(handler.index("app.releaseSingleInstanceLock()")).to be < handler.index("launchInstalledCopy(")
    expect(handler).to include("void openSyrus()")
  end

  it "recovers by polling /up from the main process and reloading" do
    expect(main_process).to include("startBackendRecoveryPolling")
    expect(main_process).to include("${serverUrl}/up")
    expect(main_process).to include("await webAppWindow?.loadServerUrl()")
  end

  it "keeps the fallback surface inert — no IPC bridge usage" do
    expect(renderer_entry).to include('view === "backend-status"')
    expect(backend_status).not_to include("window.syrusDesktop")
  end

  it "enforces a single running instance that focuses the existing one" do
    expect(main_process).to include("app.requestSingleInstanceLock(ownInstanceIdentity())")
    expect(main_process).to include('app.on("second-instance"')
  end

  it "self-installs into ~/Applications before opening any window" do
    # The DMG's double-click contract: running from the mounted image (or
    # Downloads) copies the bundle into ~/Applications, launches the copy,
    # and quits — no dialog, no drag target. The lock is released first so
    # the copy doesn't lose the single-instance race against this instance.
    when_ready = main_process[/app\.whenReady\(\)\.then\(async \(\) => \{[\s\S]*/]
    expect(when_ready).to include("shouldSelfInstall(")
    expect(when_ready).to include("installBundle(")
    expect(when_ready.index("app.releaseSingleInstanceLock()")).to be < when_ready.index("launchInstalledCopy(")
    expect(when_ready.index("launchInstalledCopy(")).to be < when_ready.index("createMenu()")

    self_install = read("electron/selfInstall.ts")
    expect(self_install).to include("/usr/bin/ditto")
    expect(self_install).to match(%r{path\.join\(homeDir, "Applications"\)})
  end

  it "shows the dock icon only while a real window is open" do
    expect(main_process).to include("const updateDockVisibility = () => {")
    expect(main_process).to include("app.dock?.show()")
    expect(main_process).to include("app.dock?.hide()")
  end

  it "opens the web window (not the browser) from launch, activate, and the tray" do
    expect(main_process).to include("await showWebAppWindow()")
    expect(main_process).to include("void openSyrus()")
    expect(main_process).not_to include("openSyrusInBrowser")
  end

  it "persists and restores the window bounds" do
    expect(main_process).to include('store.get("webAppWindowBounds", null)')
    expect(main_process).to include('store.set("webAppWindowBounds", bounds)')
  end
end

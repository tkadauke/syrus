# frozen_string_literal: true

require "json"
require "spec_helper"

RSpec.describe "desktop Electron startup" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }
  let(:package_json) { JSON.parse(File.read(File.join(desktop_root, "package.json"), encoding: "UTF-8")) }
  let(:main_process) { File.read(File.join(desktop_root, "electron/main.ts"), encoding: "UTF-8") }
  let(:app_user_cable) { File.read(File.join(desktop_root, "electron/appUserCable.ts"), encoding: "UTF-8") }
  let(:vite_config) { File.read(File.join(desktop_root, "vite.config.ts"), encoding: "UTF-8") }

  it "uses the same loopback host for Vite and Electron in dev" do
    dev_script = package_json.fetch("scripts").fetch("dev")

    expect(dev_script).to include("vite --host 127.0.0.1")
    expect(dev_script).to include("wait-on http://127.0.0.1:5173")
    expect(main_process).to include('new URL("http://127.0.0.1:5173")')
  end

  it "does not close the ActionCable websocket from its error handler" do
    expect(app_user_cable).to include("const finish = () => {")
    expect(app_user_cable).to include("socket.onerror = finish")
    expect(app_user_cable).not_to match(/socket\.onerror = \(\) => \{\s*socket\.close\(\)/m)
  end

  it "loads the preload bridge as CommonJS so Electron exposes syrusDesktop" do
    expect(File).to exist(File.join(desktop_root, "electron/preload.cts"))
    expect(main_process).to include('preload: path.join(__dirname, "preload.cjs")')
  end

  it "builds renderer assets with relative URLs for packaged file loading" do
    expect(vite_config).to include('base: "./"')
  end

  it "keeps the tray popover and native context menu on separate gestures" do
    expect(main_process).to include("tray.on(\"click\", (event) => {")
    expect(main_process).to include("tray.on(\"right-click\", showTrayContextMenu)")
    expect(main_process).to include("mainWindow?.hide()\n  tray?.popUpContextMenu(trayContextMenu())")
    expect(main_process).not_to include("tray.setContextMenu")
  end

  it "uses a macOS template image for the plain tray icon" do
    expect(File).to exist(File.join(desktop_root, "assets/syrusMenubarTemplate.png"))
    expect(main_process).to include("const createPlainTrayIcon = () => {")
    expect(main_process).to include('nativeImage.createFromPath(trayIconPath())')
    expect(main_process).to include("image.setTemplateImage(true)")
    # The menu-bar title carries the unread badge, plus a "T" on the test
    # channel so a side-by-side test build is distinguishable.
    expect(main_process).to include(
      'tray.setTitle([testMark, unreadCount > 0 ? trayBadgeLabel(unreadCount) : ""].filter(Boolean).join(" "))'
    )
    expect(main_process).to include('const testMark = currentChannel() === "test" ? "T" : ""')
  end

  it "matches the CLI inbox by fetching only actionable states" do
    expect(main_process).to include('fetchJobList(credentials, "implemented")')
    expect(main_process).to include('fetchJobList(credentials, "failed")')
    expect(main_process).not_to include('fetchJobList(credentials, "queued")')
    expect(main_process).not_to include('fetchJobList(credentials, "running")')
  end
end

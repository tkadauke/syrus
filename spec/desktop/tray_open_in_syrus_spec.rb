# frozen_string_literal: true

require "spec_helper"

# Tray "Open in Syrus" actions must land in the Syrus app window — created
# if closed, restored if minimized, focused — never the default browser
# (the legacy behavior: shell.openExternal against the instance URL left
# the native window sitting behind a duplicate browser tab). GitHub links
# (PRs, issues) are the opposite case and stay external.
RSpec.describe "desktop tray Open in Syrus" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:main) { read("electron/main.ts") }
  let(:preload) { read("electron/preload.cts") }
  let(:tray_app) { read("src/App.tsx") }

  it "focuses the app window and navigates it in-window" do
    open_in_syrus = main[/const openInSyrus[\s\S]{0,1200}/]
    # showWebAppWindow creates if closed, restores if minimized, focuses;
    # app.focus pulls the whole app forward from the tray popover.
    expect(open_in_syrus).to include("await showWebAppWindow()")
    expect(open_in_syrus).to include("app.focus({ steal: true })")
    expect(open_in_syrus).to include("resolveOpenInSyrusTarget(getServerUrl(), target)")
    expect(open_in_syrus).to include("await webAppWindow.window.loadURL(destination)")
    expect(open_in_syrus).not_to include("openExternal")
    expect(main).to include('ipcMain.handle("open-in-syrus"')
    expect(preload).to match(/openInSyrus: \(target\?: string\) => ipcRenderer\.invoke\("open-in-syrus", target\)/)
  end

  it "refuses cross-origin targets in the shared resolver" do
    resolver = read("electron/windows/openInSyrusTarget.ts")
    expect(resolver).to include("destination.origin !== instanceOrigin")
    expect(resolver).to include("return null")
    # The instance-origin authority is a named export because the shell:*
    # IPC sender validation in main.ts compares against the SAME origin —
    # "same instance" must mean one thing everywhere.
    expect(resolver).to include("export const resolveInstanceOrigin")
    expect(main).to include("resolveInstanceOrigin(getServerUrl())")
  end

  it "routes every instance-page action through openInSyrus, not the browser" do
    # Job, chat, repository, header brand, and the queued-job toasts all
    # target instance pages — they open in the app window.
    expect(tray_app).to match(%r{openInSyrus\(`/jobs/\$\{job\.id\}`\)})
    expect(tray_app).to match(%r{openInSyrus\(\s*\n?\s*`/app-shell/chats/})
    expect(tray_app).to match(%r{openInSyrus\(`/repositories/\$\{repositoryId\}`\)})
    expect(tray_app).to match(/openInSyrus\(toast\.actionUrl\)/)
    expect(tray_app).to match(/openInSyrus\(toast\.actionUrl!\)/)
    header_brand = tray_app[/function HeaderBrand[\s\S]{0,700}/]
    expect(header_brand).to include("openInSyrus()")
    # No instance URL is ever assembled for openExternal anymore.
    expect(tray_app).not_to match(/openExternal\(`\$\{normalizeInstanceUrl/)
    expect(tray_app).not_to match(/openExternal\(normalizedUrl\)/)
  end

  it "keeps GitHub links external — they need the user's browser session" do
    expect(tray_app).to match(/openExternal\(job\.pr_url\)/)
    expect(tray_app).to match(/openExternal\(notification\.pr_url\)/)
  end
end

# frozen_string_literal: true

require "spec_helper"

# The desktop app's "Uninstall Syrus…" flow: a native confirmation dialog
# hands off to the staged uninstall script, which owns the whole teardown. The
# script must therefore outlive the app: spawn detached, unref, quit. These
# assertions pin that source contract the same way backend_lifecycle_spec pins
# the lifecycle menu.
# (The scripts' own NDJSON/flag parity is pinned separately in
# spec/desktop/uninstall_spec.rb.)
RSpec.describe "desktop uninstall flow" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:staging_script) { read("scripts/stage-backend-assets.mjs") }
  let(:install_paths) { read("electron/installer/installPaths.ts") }
  let(:uninstall_command) { read("electron/installer/uninstallCommand.ts") }
  let(:main_process) { read("electron/main.ts") }

  it "stages the uninstall script alongside the installer, shell scripts executable" do
    %w[install.sh uninstall.sh].each do |asset|
      expect(staging_script).to include(%("#{asset}"))
    end
    # chmod must cover uninstall.sh too — a non-executable staged script
    # would only surface on the first real uninstall attempt.
    expect(staging_script).to match(/for \(const shellScript of \["install\.sh", "uninstall\.sh"\]\)[\s\S]{0,120}0o755/)
  end

  it "rides the existing wholesale extraResources bundle — no per-file filter to update" do
    builder_config = read("electron-builder.yml")
    expect(builder_config).to match(%r{extraResources:\s+- from: resources/backend\s+to: backend\s*\n})
  end

  it "resolves the staged uninstall script per platform, mirroring the installer" do
    expect(install_paths).to include("export const uninstallScriptPath")
    expect(install_paths).to include('"uninstall.sh"')
    expect(install_paths).to include("installerAssetsDir()")
  end

  it "always passes --yes and inverts the delete-data checkbox into --keep-data" do
    # The app shows its own confirmation; the script must never prompt again.
    expect(uninstall_command).to include('"--yes"')
    expect(uninstall_command).to include('keepData ? ["--keep-data"] : []')
    # Checkbox semantics are DELETE, flag semantics are KEEP — the inversion
    # lives at the single call site, which also scopes the teardown to THIS
    # app's channel (a test build must never uninstall production).
    expect(main_process).to include(
      "uninstallCommand(scriptPath, !choice.checkboxChecked, process.platform, uninstallAppPath(), channel)"
    )
    expect(main_process).to include("const channel = currentChannel()")
  end

  it "scopes a test build's uninstall to the test channel" do
    # buildUninstallArgs appends --channel test so uninstall.sh tears down
    # only the test stack/app/CLI/settings, never production's.
    expect(uninstall_command).to include('channel === "test" ? ["--channel", "test"] : []')
  end

  it "tells uninstall.sh where the running app bundle lives — darwin only, single --app-path= token" do
    # The dialog promises to remove "the Syrus app". Self-install accepts
    # both /Applications and ~/Applications, so the script must be told
    # which bundle is real instead of guessing; uninstall.sh re-validates
    # the value (absolute, /Syrus.app, under an Applications dir).
    expect(uninstall_command).to include('[`--app-path=${appPath}`]')
    derivation = main_process[/const uninstallAppPath = \(\): string \| null => \{[\s\S]*?\n\}/]
    expect(derivation).to include('process.platform !== "darwin"')
    expect(derivation).to include('bundlePathFromExecPath(app.getPath("exe"))')
    # Only trust the derived path when it actually looks like a bundle.
    expect(derivation).to include('bundle.endsWith(".app") ? bundle : null')
  end

  it "drives uninstall.sh through bash" do
    expect(uninstall_command).to include('command: "/bin/bash"')
  end

  it "offers Uninstall Syrus… as a low-prominence app-menu item near Quit" do
    expect(main_process).to include('label: "Uninstall Syrus…"')
    # Its own separator group directly above Quit in the app-name submenu.
    expect(main_process).to match(/"Uninstall Syrus…"[\s\S]{0,200}\{ role: "quit" \}/)
    expect(main_process).to include("void confirmAndUninstall()")
  end

  it "confirms with Cancel as the default and a default-unchecked delete-data checkbox" do
    confirm = main_process[/const confirmAndUninstall = async \(\) => \{[\s\S]*?\n\}/]
    expect(confirm).to include('type: "warning"')
    expect(confirm).to include('buttons: ["Cancel", "Uninstall"]')
    expect(confirm).to include("defaultId: 0")
    expect(confirm).to include("cancelId: 0")
    expect(confirm).to include("checkboxChecked: false")
    expect(confirm).to include("cannot be undone")
    # The message must spell out the blast radius before the user confirms.
    %w[command-line Docker].each { |scope| expect(confirm).to include(scope) }
    expect(confirm).to include("if (choice.response !== 1)")
  end

  it "spawns the script detached so it outlives the app, then quits after a beat" do
    confirm = main_process[/const confirmAndUninstall = async \(\) => \{[\s\S]*?\n\}/]
    expect(confirm).to include(
      'const child = spawn(command, args, { detached: true, stdio: "ignore", windowsHide: false })'
    )
    expect(confirm).to include("child.unref()")
    # Quit comes AFTER the spawn — the script does the teardown, including
    # removing the app; the app just gets out of the way.
    expect(confirm).to match(/spawn\(command, args[\s\S]*?setTimeout\(\(\) => \{[\s\S]{0,80}app\.quit\(\)/)
    # No competing teardown from the app itself: quitting never stops the
    # stack (see backend_lifecycle_spec), and this flow must not start to —
    # the script's `compose down` is the only teardown actor.
    expect(confirm).not_to include("stopBackend")
    expect(confirm).not_to include("compose(")
  end

  it "surfaces a spawn failure instead of quitting with nothing uninstalled" do
    confirm = main_process[/const confirmAndUninstall = async \(\) => \{[\s\S]*?\n\}/]
    # Without an "error" listener a failed spawn is an uncaught main-process
    # exception AND a silent no-op uninstall: the 500ms timer quits the app
    # anyway.
    expect(confirm).to include('child.once("error"')
    # The pending quit is cancelled FIRST — the timer and the error dialog
    # must never both fire.
    expect(confirm).to match(/child\.once\("error"[\s\S]{0,200}clearTimeout\(quitTimer\)/)
    expect(confirm).to match(/clearTimeout\(quitTimer\)[\s\S]*?showErrorBox/)
    # The message names the script that failed to launch, and the app stays
    # open — no quit on the error path.
    expect(confirm).to match(/showErrorBox\([\s\S]{0,300}\$\{scriptPath\}/)
    error_handler = confirm[/child\.once\("error"[\s\S]*?\n  \}\)/]
    expect(error_handler).not_to include("app.quit")
  end
end

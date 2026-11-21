# frozen_string_literal: true

require "spec_helper"

# The desktop app's persistent config moved out of main.ts so the onboarding,
# installer, and web-container modules can share it without import cycles.
# These assertions pin the module boundaries and the zero-prompt migration
# for users who configured the tray app before backend modes existed.
RSpec.describe "desktop settings and credentials modules" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }
  let(:main_process) { File.read(File.join(desktop_root, "electron/main.ts"), encoding: "UTF-8") }
  let(:settings_module) { File.read(File.join(desktop_root, "electron/settings.ts"), encoding: "UTF-8") }
  let(:credentials_module) { File.read(File.join(desktop_root, "electron/credentialsStore.ts"), encoding: "UTF-8") }
  let(:channel_module) { File.read(File.join(desktop_root, "electron/channel.ts"), encoding: "UTF-8") }

  it "owns the electron-store schema in settings.ts, not main.ts" do
    expect(settings_module).to include("new Store<DesktopStore>")
    expect(main_process).not_to include("new Store<")
    expect(main_process).to include('from "./settings.js"')
  end

  it "adds the backend-mode keys with onboarding-pending defaults" do
    %w[backendMode serverUrl localInstall webAppWindowBounds onboardingCompletedAt].each do |key|
      expect(settings_module).to include("#{key}:")
    end
    expect(settings_module).to include('backendMode: ""')
    expect(settings_module).to include("localInstall: null")
  end

  it "forks the app name per channel BEFORE the store captures userData" do
    # Load-bearing: Electron derives userData (and the single-instance lock)
    # from app.getName(), which reads the bundled package.json ("Syrus") — NOT
    # the electron-builder-renamed .app bundle. Without app.setName() a test
    # build's userData/lock collide with the production install, breaking
    # side-by-side. It MUST run before `new Store(...)`.
    expect(settings_module).to include("app.setName(channelProductName(currentChannel()))")
    set_name_at = settings_module.index("app.setName(channelProductName")
    store_at = settings_module.index("new Store<DesktopStore>")
    expect(set_name_at).not_to be_nil
    expect(store_at).not_to be_nil
    expect(set_name_at).to be < store_at
    expect(channel_module).to include('channel === "test" ? "Syrus Test" : "Syrus"')
  end

  it "keeps the local install state under ~/.syrus/local, per channel" do
    # localStateDir derives from the channel; the concrete path (local /
    # local-test) is built in channel.ts's stackIdentity so a side-by-side
    # test build never adopts or clobbers the production stack.
    expect(settings_module).to include("currentStackIdentity().stateDir")
    expect(channel_module).to include('test ? "local-test" : "local"')
  end

  it "migrates existing users without prompting: credentials mean remote, a local .env means local" do
    expect(settings_module).to include("export const migrateBackendConfig")
    # Remote adoption (existing tray credentials) is checked before local.
    expect(settings_module.index("credentialsUrl")).to be < settings_module.index('".env"')
    expect(settings_module).to match(/SYRUS_PORT=/)
  end

  it "runs the migration at most once, so a cleared config reopens onboarding" do
    # After "Run Setup Again…" clears backendMode, a relaunch must NOT
    # silently re-adopt remote mode from the surviving credentials file.
    expect(settings_module).to include('store.get("backendConfigMigratedAt", "") !== ""')
    expect(settings_module).to include('store.set("backendConfigMigratedAt", new Date().toISOString())')
    clear_config = settings_module[/export const clearBackendConfig[\s\S]*?\n\}/]
    expect(clear_config).not_to include("backendConfigMigratedAt")
  end

  it "runs the migration on startup after credentials load" do
    expect(main_process).to include("await migrateBackendConfig(cachedCredentials?.url ?? null)")
    expect(main_process.index("await loadCredentials()")).to be < main_process.index("await migrateBackendConfig")
  end

  it "owns the credentials file format in credentialsStore.ts, not main.ts" do
    # The credentials path is per-channel (credentials / credentials.test) so
    # the test build shares its file with the syrus-test CLI, not production's.
    expect(credentials_module).to include("currentStackIdentity().credentialsFile")
    # Written to a fresh 0600 file and renamed over the path (never through
    # a symlink); desktop/src/credentialsStore.test.ts exercises it.
    expect(credentials_module).to include('fs.open(tempPath, "wx", 0o600)')
    expect(credentials_module).to include("fs.rename(tempPath, filePath)")
    expect(main_process).to include('from "./credentialsStore.js"')
    expect(main_process).not_to include("const parseCredentials")
    expect(main_process).not_to include('".syrus", "credentials"')
    expect(channel_module).to include('test ? "credentials.test" : "credentials"')
  end

  it "tolerates a missing credentials file on read and delete" do
    expect(credentials_module.scan(/ENOENT/).length).to eq(2)
  end
end

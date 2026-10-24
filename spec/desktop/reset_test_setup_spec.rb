# frozen_string_literal: true

require "spec_helper"

# "Reset Test Setup…" — a TEST-CHANNEL-ONLY menu action that wipes this build's
# whole slate (backend stack + data volume, state dir, credentials, app setup)
# and relaunches into onboarding, so the initial setup flow can be exercised
# again from scratch. The load-bearing contract is that it can NEVER touch a
# production install: it is hidden on stable, guarded in code, and every target
# is a test-channel resource. These assertions pin that source contract.
RSpec.describe "desktop reset test setup" do
  let(:desktop_root) { File.expand_path("../../desktop", __dir__) }

  def read(relative_path)
    File.read(File.join(desktop_root, relative_path), encoding: "UTF-8")
  end

  let(:main) { read("electron/main.ts") }
  let(:i18n_catalog) { read("electron/i18nCatalog.ts") }
  let(:backend_lifecycle) { read("electron/installer/backendLifecycle.ts") }

  describe "wipeBackendStack (backendLifecycle.ts)" do
    it "is hard-gated to the test channel — a stable build must never reach down -v" do
      # On stable, currentStackIdentity().project is production's `syrus`; this
      # helper does `down -v` (data destruction), so it refuses off the test
      # channel BEFORE touching any project.
      wipe = backend_lifecycle[/export const wipeBackendStack[\s\S]*?\n\}/]
      expect(wipe).to include('if (currentChannel() !== "test") {')
      expect(wipe).to include('throw new Error("wipeBackendStack is only available on the test channel")')
    end

    it "tears the stack down with volumes, then removes the named volumes by prefix as a fallback" do
      wipe = backend_lifecycle[/export const wipeBackendStack[\s\S]*?\n\}/]
      # down -v --remove-orphans drops containers + Compose-managed volumes.
      expect(wipe).to include('await compose(["down", "-v", "--remove-orphans"])')
      # Belt-and-braces by-name removal, scoped strictly to THIS channel's
      # <project>_ volumes (never an unscoped `docker volume prune`).
      expect(wipe).to include("for (const volume of [identity.dataVolume, identity.searchVolume]) {")
      expect(wipe).to include('await execFileAsync(dockerBinary, ["volume", "rm", "-f", volume]')
      # Best-effort: the compose failure is swallowed so a stopped daemon or a
      # missing compose file can't wedge the reset.
      expect(wipe).to match(/await compose\(\["down"[\s\S]{0,200}\} catch \{/)
    end
  end

  describe "resetTestSetup (main.ts)" do
    it "is gated to the test channel" do
      reset = main[/const resetTestSetup = async \(\): Promise<void> => \{[\s\S]*?\n\}/]
      expect(reset).to include('if (currentChannel() !== "test") {')
      expect(reset).to include("Reset Test Setup is only available on the test channel.")
    end

    it "wipes the stack, then the state dir + credentials, then resets the app store — in that order" do
      reset = main[/const resetTestSetup = async \(\): Promise<void> => \{[\s\S]*?\n\}/]
      # Stack down FIRST (while the state dir still holds the compose file),
      # then delete the channel-scoped state dir + credentials, then clear the
      # test store. All three targets are test-channel-scoped helpers.
      expect(reset).to match(
        /backendLifecycle\.wipeBackendStack\(\)[\s\S]*?fs\.rm\(localStateDir\(\), \{ recursive: true, force: true \}\)[\s\S]*?deleteCredentialsFile\(\)[\s\S]*?store\.clear\(\)/
      )
    end
  end

  describe "confirmAndResetTestSetup (main.ts)" do
    let(:confirm) { main[/const confirmAndResetTestSetup = async \(\) => \{[\s\S]*?\n\}/] }

    it "no-ops off the test channel even if somehow invoked" do
      expect(confirm).to match(/if \(currentChannel\(\) !== "test"\) \{\s*\n\s*return/)
    end

    it "refuses while a backend update is in flight (its detached installer would race the wipe)" do
      # updateBackend spawns a detached install.sh against the state dir; wiping
      # under it would delete files it's reading and let it re-create the .env
      # after the reset. Refuse cleanly until it finishes.
      expect(confirm).to match(/if \(backendLifecycle\.backendBusy\(\)\) \{[\s\S]{0,300}return/)
      expect(confirm).to include('t("dialog.finishing_update")')
      expect(i18n_catalog).to include('"dialog.finishing_update": "Finishing backend update…"')
    end

    it "shows an info+confirm dialog that names every wiped resource" do
      expect(confirm).to include('type: "warning"')
      # The four wipe targets are each spelled out (the info dialog the reset UX
      # promises), keyed off the channel identity so the paths are accurate.
      expect(confirm).to include("${identity.project}")
      expect(confirm).to include("${identity.stateDir}")
      expect(confirm).to include("${identity.credentialsFile}")
      expect(confirm).to include("backend connection and onboarding progress")
    end

    it "reassures that production is untouched and images are kept" do
      expect(confirm).to include("Your production Syrus stays completely untouched")
      expect(confirm).to include("NOT removed")
      expect(confirm).to include("Downloaded Docker images are kept")
    end

    it "defaults to Cancel and only proceeds on the explicit Reset button" do
      expect(confirm).to include('buttons: [t("common.cancel"), t("dialog.reset_button")]')
      expect(i18n_catalog).to include('"dialog.reset_button": "Reset & Restart"')
      expect(confirm).to include("defaultId: 0")
      expect(confirm).to include("cancelId: 0")
      expect(confirm).to include("if (choice.response !== 1) {")
    end

    it "surfaces a partial-wipe failure instead of relaunching into a broken state" do
      expect(confirm).to include('dialog.showErrorBox(')
      expect(confirm).to include('"Reset didn\'t finish"')
      # The error path returns WITHOUT relaunching.
      expect(confirm).to match(/showErrorBox\([\s\S]{0,400}return\s*\n\s*\}/)
    end

    it "relaunches a fresh process for a true first run" do
      expect(confirm).to match(/isQuitting = true\s*\n\s*app\.relaunch\(\)\s*\n\s*app\.exit\(0\)/)
    end
  end

  describe "the app menu" do
    it "shows Reset Test Setup… only on the test channel, in the destructive group above Uninstall" do
      # Spread-guarded so the item is absent from a stable build's menu entirely.
      expect(main).to match(
        /currentChannel\(\) === "test"\s*\n\s*\? \[\s*\n\s*\{\s*\n\s*label: t\("shell\.reset_test"\)[\s\S]{0,160}confirmAndResetTestSetup\(\)/
      )
      # It sits directly above "Uninstall Syrus…" (both are wipe actions).
      expect(main).to match(/confirmAndResetTestSetup\(\)[\s\S]{0,200}label: t\("shell\.uninstall"\)/)
    end
  end
end

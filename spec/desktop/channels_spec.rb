# frozen_string_literal: true

require "spec_helper"

# Side-by-side channels: a "test" build installs as Syrus Test.app beside a
# release, on its own backend stack, port, credentials, and update posture.
# These assertions pin the CI wiring and packaging assets that fork the two
# channels so a test build can never install over — or share state with — a
# production install.
RSpec.describe "desktop channels" do
  root = File.expand_path("../..", __dir__)
  desktop_root = File.join(root, "desktop")

  def self.read(path)
    File.read(path, encoding: "UTF-8")
  end

  build_app = read(File.join(root, ".github/workflows/_build-app.yml"))
  release = read(File.join(root, ".github/workflows/release.yml"))
  test_build = read(File.join(root, ".github/workflows/test-build.yml"))
  make_ico = read(File.join(desktop_root, "scripts/make-ico.mjs"))
  install_sh = read(File.join(root, "install.sh"))
  install_ps1 = read(File.join(root, "install.ps1"))
  uninstall_sh = read(File.join(root, "uninstall.sh"))
  uninstall_ps1 = read(File.join(root, "uninstall.ps1"))
  gitattributes = read(File.join(root, ".gitattributes"))
  main_ts = read(File.join(desktop_root, "electron/main.ts"))
  installer_driver = read(File.join(desktop_root, "electron/installer/installerDriver.ts"))
  windows_resume = read(File.join(desktop_root, "electron/installer/windowsResume.ts"))

  describe "_build-app.yml channel input" do
    it "declares a channel input defaulting to stable" do
      expect(build_app).to include("channel:")
      expect(build_app).to match(/channel:.*\n(.*\n)*?\s*default: stable/)
    end

    it "resolves per-channel product name, appId, and icons at the job level" do
      expect(build_app).to include("PRODUCT: ${{ inputs.channel == 'test' && 'Syrus Test' || 'Syrus' }}")
      expect(build_app).to include("APP_ID: ${{ inputs.channel == 'test' && 'app.syrus.desktop.test' || 'app.syrus.desktop' }}")
      expect(build_app).to include("MAC_ICON: ${{ inputs.channel == 'test' && 'build/icon-test.png' || 'build/icon.png' }}")
      expect(build_app).to include("WIN_ICON: ${{ inputs.channel == 'test' && 'build/icon-test.ico' || 'build/icon.ico' }}")
    end

    it "passes the overrides to electron-builder on macOS" do
      expect(build_app).to include('-c.productName="$PRODUCT"')
      expect(build_app).to include('-c.appId="$APP_ID"')
      expect(build_app).to include('-c.mac.icon="$MAC_ICON"')
      # ${version} must stay literal for electron-builder to expand.
      expect(build_app).to include(%q{-c.dmg.title="$PRODUCT "'${version}'})
    end

    it "passes the overrides to electron-builder on Windows, including the shortcut name" do
      expect(build_app).to include('-c.win.icon="$WIN_ICON"')
      expect(build_app).to include('-c.nsis.shortcutName="$PRODUCT"')
    end

    it "forks the Windows install directory via the package name (one-click NSIS derives $INSTDIR from it, not productName)" do
      expect(build_app).to include("PKG_NAME: ${{ inputs.channel == 'test' && 'syrus-test-desktop' || 'syrus-desktop' }}")
      expect(build_app).to include('-c.extraMetadata.name="$PKG_NAME"')
    end

    it "names the verify + stage artifacts by the channel product name" do
      expect(build_app).to include('APP="desktop/out/mac-universal/$PRODUCT.app"')
      expect(build_app).to include('"desktop/out/$PRODUCT-$VERSION-universal.dmg"')
      expect(build_app).to include('"$env:PRODUCT-Setup-*.exe"')
      # No stray hardcoded bundle name remains in the mac verify/stage steps.
      expect(build_app).not_to include("desktop/out/mac-universal/Syrus.app")
    end
  end

  describe "callers select their channel" do
    it "release.yml builds the stable channel" do
      expect(release).to include("channel: stable")
    end

    it "test-build.yml builds the test channel" do
      expect(test_build).to include("channel: test")
    end
  end

  describe "stack isolation hardening" do
    it "stamps the channel project name into the synced compose file so manual `docker compose` from the state dir never hits the production project" do
      expect(install_sh).to include('sed "s|^name: syrus\\$|name: $PROJECT|"')
      expect(install_ps1).to include('[regex]::Replace($composeText, "(?m)^name: syrus$", "name: $project")')
    end

    it "scopes the uninstall image sweep to the channel's tag shape (test-* vs semver), like imageCleanup.ts" do
      expect(uninstall_sh).to include("test-*|*-test.[0-9]*) tag_channel=test ;;")
      expect(uninstall_sh).to include('[ "$tag_channel" = "$CHANNEL" ] || continue')
      expect(uninstall_ps1).to include('if ($tag -match "^test-" -or $tag -match "-test\\.\\d+$") { "test" } else { "stable" }')
      expect(uninstall_ps1).to include('if ($tagChannel -ne $script:Channel) { continue }')
    end
  end

  # Adversarial-review round: cross-channel bugs where a TEST build could reach
  # into the PRODUCTION stack, and one production-regression the first port
  # re-stamp introduced.
  describe "adversarial-review hardening" do
    it "normalizes the compose file to LF BEFORE the project-name stamp (a CRLF no-op would delete production's volume)" do
      # .NET's (?m)$ matches only before \n, so on a CRLF docker-compose.yml the
      # "^name: syrus$" replace silently no-ops — leaving `name: syrus` in the
      # test state dir where a bare `docker compose down -v` hits production.
      # The compose read must normalize to LF (like the .env path) immediately
      # BEFORE the $composeText project-name stamp runs. This match ties the
      # normalize to the compose stamp specifically (the .env normalize is
      # followed by a $content SECRET_KEY_BASE stamp, not this one).
      expect(install_ps1).to match(/-replace "`r`n", "`n"\s*\n\s*\$composeText = \[regex\]::Replace\(\$composeText, "\(\?m\)\^name: syrus\$"/)
    end

    it "pins the compose + env deploy assets to LF at the source so no consumer sees CRLF" do
      # Root-cause fix: a Windows checkout (autocrlf=true, GitHub's default) must
      # not hand the installers CRLF in the first place.
      expect(gitattributes).to include("docker-compose.yml text eol=lf")
      expect(gitattributes).to include("compose.env.example text eol=lf")
    end

    it "gates the Preferences 'Add Claude Code skill' IPC path off on the test channel" do
      # The three other skill-write paths were gated; this ungated IPC handler
      # let a test build overwrite the shared production ~/.claude/skills/syrus.
      expect(main_ts).to include('ipcMain.handle("install-syrus-cli"')
      expect(main_ts).to include(
        'currentChannel() === "test" && options?.withSkill ? { ...options, withSkill: false } : options'
      )
    end

    it "falls back to the channel's own CLI binary, never a hardcoded stable 'syrus'" do
      # A momentary probe miss on the test channel must not run production `syrus`
      # (which resolves to the stable profile + backend).
      expect(main_ts).to include('(await syrusCliBinary()) ?? cliBinaryName()')
      expect(main_ts).not_to include('(await syrusCliBinary()) ?? "syrus"')
    end

    it "re-stamps the adopted .env port ONLY on the test channel (stable keeps a custom port verbatim)" do
      # The unconditional re-stamp rewrote a stable install's non-default port
      # back to 3000; gate it, and use restampEnvPort which APPENDS a missing line.
      expect(installer_driver).to match(/identity\.channel === "test"[\s\S]{0,200}restampEnvPort\(contents, identity\.defaultPort\)/)
    end

    it "forks the Windows RunOnce value name per channel so an uninstall can't drop the other channel's resume" do
      expect(windows_resume).to include('channel === "test" ? "SyrusResumeSetupTest" : "SyrusResumeSetup"')
      expect(uninstall_ps1).to include('if ($script:Channel -eq "test") { "SyrusResumeSetupTest" } else { "SyrusResumeSetup" }')
      expect(uninstall_ps1).to include("-Name $runOnceValueName")
    end
  end

  describe "packaging assets" do
    it "commits an amber-badged test icon (mac PNG + Windows ICO)" do
      expect(File).to exist(File.join(desktop_root, "build/icon-test.png"))
      expect(File).to exist(File.join(desktop_root, "build/icon-test.ico"))
    end

    it "make-ico.mjs builds either the stable or the test .ico by name" do
      expect(make_ico).to include('const name = process.argv[2] || "icon"')
      expect(make_ico).to include("${name}.png")
      expect(make_ico).to include("${name}.ico")
    end
  end
end

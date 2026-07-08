# frozen_string_literal: true

require "json"
require "yaml"
require "spec_helper"

# Auto-update and the release pipeline. The invariants here are the ones
# that strand users when broken: only signed builds may publish, the zip
# target feeds Squirrel.Mac, and the backend image must exist before the
# tag that pins it.
RSpec.describe "desktop auto-update and release pipeline" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:desktop_root) { File.join(repo_root, "desktop") }

  def read(*segments)
    File.read(File.join(*segments), encoding: "UTF-8")
  end

  let(:app_updates) { read(desktop_root, "electron/appUpdates.ts") }
  let(:main_process) { read(desktop_root, "electron/main.ts") }
  let(:release_workflow) { read(repo_root, ".github/workflows/release.yml") }
  let(:ci_workflow) { read(repo_root, ".github/workflows/desktop-ci.yml") }

  it "keeps auto-update inert for unsigned dev builds and test runs" do
    expect(app_updates).to include("app.isPackaged && !process.env.SYRUS_DISABLE_AUTO_UPDATE")
  end

  it "checks on launch and every six hours, logging errors instead of dialoging" do
    expect(app_updates).to include("CHECK_INTERVAL_MS = 6 * 60 * 60 * 1_000")
    expect(app_updates).to match(/autoUpdater\.on\("error"[\s\S]*?console\.warn/)
    expect(app_updates).not_to include("dialog.show")
  end

  it "offers the restart from both the app menu and the tray, plus a manual check" do
    expect(main_process).to include("Restart to update Syrus")
    expect(main_process).to match(/trayContextMenu[\s\S]{0,80}updateMenuItems\(\)/)
    expect(main_process).to include('"Check for Updates…"')
    expect(main_process).to include("appUpdates.initAutoUpdates")
  end

  it "sets the quit flag before installing so hide-on-close cannot abort the update" do
    # quitAndInstall closes all windows before any quit event fires; without
    # the flag the tray's hide-on-close handler preventDefaults and the
    # update silently never installs.
    expect(main_process).to match(/isQuitting = true\s*\n\s*appUpdates\.quitAndInstallUpdate\(\)/)
    expect(main_process).to match(/onBeforeQuitForUpdate: \(\) => \{\s*\n\s*isQuitting = true/)
    expect(app_updates).to include('nativeAutoUpdater.on("before-quit-for-update"')
  end

  it "offers the pinned backend upgrade after an app update instead of mutating silently" do
    lifecycle = read(desktop_root, "electron/installer/backendLifecycle.ts")

    # main.ts compares the release manifest pin against the install's .env pin
    # once the backend is up, and asks before applying.
    expect(main_process).to include("offerBackendUpdateIfPinned")
    expect(main_process).to match(/ensureRunning\(\)\.then\(\(\) => offerBackendUpdateIfPinned\(\)\)/)
    expect(main_process).to include("readBackendManifest")
    expect(main_process).to include('"Update Backend"')

    # The update re-runs the bundled installer against the state dir — the
    # same audited pull/up/health path a fresh install takes.
    expect(lifecycle).to match(/currentImagePin[\s\S]*?SYRUS_IMAGE=/)
    expect(lifecycle).to match(/updateBackend[\s\S]*?"--image",\s*\n\s*image/)
    expect(lifecycle).to match(/updateBackend = async[\s\S]*?"--skip-runtime-install"/)
    expect(lifecycle).to include('createWriteStream(path.join(stateDir(), "install.log"), { flags: "a" })')
  end

  it "declares the electron-updater dependency" do
    package_json = JSON.parse(read(desktop_root, "package.json"))
    expect(package_json.dig("dependencies", "electron-updater")).not_to be_nil
  end

  it "release workflow is a manual, atomic, single-entrypoint pipeline" do
    workflow = YAML.safe_load(release_workflow)
    # Manually triggered — the pipeline computes the version, no tag-first
    # dance. (YAML parses the `on:` key as the boolean `true`, so the trigger
    # and its inputs are asserted against the raw text.)
    expect(release_workflow).to include("workflow_dispatch:")
    expect(release_workflow).to include("bump:")
    expect(release_workflow).to include("version:")
    expect(release_workflow).to include("dry_run:")
    expect(release_workflow).to match(/options:\s*\[patch, minor, major\]/)
    # Needs write to create the tag/release/commit AND push the image.
    expect(workflow.dig("permissions", "contents")).to eq("write")
    expect(workflow.dig("permissions", "packages")).to eq("write")
    # One coherent pipeline: build everything, then a single publish job. The
    # backend builds per-arch (build-backend matrix) then merge-backend
    # assembles the multi-arch manifest.
    expect(workflow["jobs"].keys).to include(
      "prepare", "build-backend", "merge-backend", "build-cli", "build-mac", "build-windows", "publish", "publish-website"
    )
    # Atomic: publish waits for the merged image + every app and is skipped on a
    # dry run, so a failure means nothing is tagged, released, or promoted.
    # (merge-backend transitively needs build-backend, so both must pass.)
    expect(workflow.dig("jobs", "publish", "needs")).to include(
      "merge-backend", "build-cli", "build-mac", "build-windows"
    )
    expect(workflow.dig("jobs", "publish", "if")).to include("dry_run == 'false'")
    expect(workflow.dig("jobs", "publish-website", "if")).to include("dry_run == 'false'")
  end

  it "release workflow only ships signed builds and STAGES them (never publishes mid-build)" do
    # Signing is a hard requirement — even a dry run signs (it's the fragile
    # part worth rehearsing). Both platform guards refuse to build without it,
    # and forceCodeSigning turns electron-builder's silent skip into a failure.
    expect(release_workflow.scan("A signed build is required").length).to be >= 2
    expect(release_workflow.scan("-c.forceCodeSigning=true").length).to be >= 2
    # The signed build/sign steps are NOT gated on a real run — dry runs sign
    # too. There is no unsigned dry-run build step anymore.
    expect(release_workflow).not_to include("Build unsigned (dry run)")
    # Build jobs stage artifacts — they never publish to the release directly
    # (only the atomic publish job does). So no build uses --publish always.
    expect(release_workflow).not_to include("--publish always")
    expect(release_workflow).to include("--publish never")
    # Credential preflights fail in seconds, not after a 15-minute build.
    expect(release_workflow).to include("Preflight: Apple signing credentials")
    expect(release_workflow).to include("Preflight: Azure credentials")
    # Notarization failures surface the developer log, and stapler runs on the
    # .app — the DMG container carries no ticket (Error 65 by design).
    expect(release_workflow).to include("Fetch notarytool developer log")
    expect(release_workflow).to match(/stapler validate "\$APP"/)
    expect(release_workflow).not_to match(/stapler validate "\$dmg"/)
    # Runaway builds must not burn the 6-hour default job timeout.
    workflow = YAML.safe_load(release_workflow)
    expect(workflow.dig("jobs", "build-mac", "timeout-minutes")).to be_a(Integer)
    expect(workflow.dig("jobs", "build-windows", "timeout-minutes")).to be_a(Integer)
    expect(workflow.dig("jobs", "build-backend", "timeout-minutes")).to be_a(Integer)
  end

  it "release workflow builds each arch natively (no QEMU) and merges by digest" do
    workflow = YAML.safe_load(release_workflow)
    # build-backend is a per-arch matrix on native runners — amd64 on
    # ubuntu-latest, arm64 on ubuntu-24.04-arm — so NO QEMU emulation.
    expect(release_workflow).to include("ubuntu-24.04-arm")
    expect(release_workflow).not_to include("setup-qemu-action")
    expect(workflow.dig("jobs", "build-backend", "strategy", "matrix", "include")).to be_an(Array)
    # Each leg builds + integration-tests its own arch via bin/publish-image
    # --no-push (identical on dry AND real runs → both arches always exercised),
    # then real runs push that arch BY DIGEST.
    expect(release_workflow).to match(/bin\/publish-image "\$VERSION" --no-push/)
    expect(release_workflow).not_to include("--multi-arch") # QEMU path is gone from CI
    expect(release_workflow).to include("push-by-digest=true")
    # Per-arch cache refs so the two legs don't clobber each other's mode=max cache.
    expect(release_workflow).to include("ghcr.io/tkadauke/syrus-backend:buildcache-${{ matrix.arch }}")
    # merge-backend assembles the digests into the versioned multi-arch tag; it's
    # skipped on dry runs (nothing was pushed).
    expect(release_workflow).to include("docker buildx imagetools create")
    expect(release_workflow).to match(/imagetools create -t "\$IMAGE:\$VERSION"/)
    expect(workflow.dig("jobs", "merge-backend", "if")).to include("dry_run == 'false'")
    # ...and :latest is moved to :VERSION only in the atomic publish job.
    expect(release_workflow).to match(/imagetools create -t "\$IMAGE:latest" "\$IMAGE:\$VERSION"/)
    # The fat image still overflows the runner without freeing disk first.
    expect(release_workflow).to match(/Free disk space/)
  end

  it "writes LLM highlights over the mechanical changelog, with an optional review gate" do
    workflow = YAML.safe_load(release_workflow)
    # Hybrid notes: GitHub's mechanical --generate-notes stays (hallucination-proof
    # PR list) AND Claude highlights are written on top via bin/release-notes.
    expect(release_workflow).to include("--generate-notes")
    expect(release_workflow).to match(%r{bin/release-notes "\$VERSION" --stdout})
    expect(release_workflow).to include("Full changelog")
    expect(release_workflow).to include("secrets.CLAUDE_API_KEY")
    # Optional review gate: a review_notes input holds the release as a draft.
    expect(release_workflow).to include("review_notes:")
    expect(workflow.dig("jobs", "prepare", "outputs", "review_notes")).to be_a(String)
    # The go-live flip is skipped when review_notes is set (draft stays for a human).
    flip = release_workflow[/name: Publish the release[\s\S]{0,220}/]
    expect(flip).to include("review_notes != 'true'")
    expect(flip).to include("--draft=false")
    # publish-website waits for a real publish, not a held draft.
    expect(workflow.dig("jobs", "publish-website", "if")).to include("review_notes != 'true'")
  end

  it "release publish is near-atomic: draft release, then flip, with rollback" do
    # The only visible go-live is flipping the draft to published; everything
    # before it is invisible (draft) or reversible (:latest), and a failure
    # rolls it all back — no half-published state.
    expect(release_workflow).to match(/release create "\$TAG" --draft/)
    # The `release create` subcommand lives in the args array, so the call must
    # be `gh "${args[@]}"` — never `gh release create "${args[@]}"`, which would
    # double the subcommand (`gh release create release create …`) and make gh
    # treat the extra `create` as a missing asset file. (Regression: this bug
    # broke the first real publish; dry runs skip publish so it was never hit.)
    expect(release_workflow).to include('gh "${args[@]}" "${assets[@]}"')
    expect(release_workflow).not_to include('gh release create "${args[@]}"')
    expect(release_workflow).to include("--draft=false") # the go-live flip
    rollback = release_workflow[/name: Roll back on failure[\s\S]{0,900}/]
    expect(rollback).to include("if: failure()")
    expect(rollback).to include("gh release delete \"$TAG\" --yes --cleanup-tag")
    expect(rollback).to match(/imagetools create -t "\$IMAGE:latest" "\$IMAGE@\$OLD_LATEST"/)
  end

  it "release workflow computes a tag-driven version and never interpolates it into shell" do
    # The git tag is the source of truth. CI computes the version, stamps it
    # into each build with `npm version` (so the shipped apps carry it), but
    # NEVER commits back to main — desktop/package.json stays a 0.0.0 sentinel.
    expect(release_workflow).to include("Compute the release version")
    expect(release_workflow.scan(/npm --prefix desktop version "\$VERSION"/).length).to be >= 2
    # No push-to-main bump step: publish only tags + releases.
    expect(release_workflow).not_to include("Commit the version bump to main")
    expect(release_workflow).not_to match(/git push origin "HEAD:/)
    # The version/tag are attacker-influenceable (whoever can dispatch); they
    # reach run: bodies only via env, never inline ${{ }} interpolation.
    run_bodies = release_workflow.scan(/run: \|[\s\S]*?(?=\n      - |\n  [a-z]|\z)/)
    run_bodies.each do |body|
      expect(body).not_to match(/\$\{\{\s*needs\.prepare\.outputs\.(version|tag)\s*\}\}/)
      expect(body).not_to match(/\$\{\{\s*inputs\.(version|bump)\s*\}\}/)
    end
  end

  it "release workflow guarantees the bundled CLI: Go on both desktop runners, presence asserted" do
    # 0.1.1/0.1.2 shipped with NO Resources/cli: macos-15 has no Go, and
    # stage-cli.mjs exited 0 after wiping the staging dir, so every in-app
    # CLI/skill install died with ENOENT. Three layers now prevent it:
    # (1) stage-cli hard-fails under SYRUS_RELEASE_BUILD=1 (pinned in
    # cli_install_spec), (2) BOTH desktop jobs pin the Go toolchain from
    # cli/go.mod — same source of truth as build-cli — and (3) the verify
    # steps assert the binaries are actually inside the packaged app.
    setup_go = release_workflow.scan(%r{uses: actions/setup-go@\S+\s+with:\s+go-version-file: cli/go\.mod})
    expect(setup_go.length).to be >= 3 # build-cli + build-mac + build-windows
    # setup-go's default cache expects go.sum at the repo root; ours is under
    # cli/, so every setup-go step must point the cache there or it caches
    # nothing (with a warning) on every release run.
    expect(release_workflow.scan("cache-dependency-path: cli/go.sum").length).to be >= 3

    mac_job = release_workflow[/^  build-mac:[\s\S]*?(?=^  build-windows:)/]
    expect(mac_job).to include("go-version-file: cli/go.mod")
    windows_job = release_workflow[/^  build-windows:[\s\S]*?(?=^  publish:)/]
    expect(windows_job).to include("go-version-file: cli/go.mod")

    # Layer (1) only arms itself when the workflow declares a release build:
    # stage-cli's hard-fail and the DMG's release naming both key on
    # SYRUS_RELEASE_BUILD=1, so BOTH desktop build steps must set it.
    expect(mac_job).to include('SYRUS_RELEASE_BUILD: "1"')
    expect(windows_job).to include('SYRUS_RELEASE_BUILD: "1"')

    # The mac build's retry-once loop must treat the stage-cli hard-fail as
    # deterministic (like a notarization "Invalid") — retrying a missing Go
    # toolchain just burns 90s and mislabels the failure as transient.
    mac_build_step = release_workflow[/name: Build, sign, and notarize[\s\S]{0,1800}/]
    expect(mac_build_step).to include("grep -qF 'stage-cli: Go toolchain not found'")

    # macOS: both darwin arches ride the universal app (ensureCliCurrent
    # installs the one matching the running arch), asserted executable.
    mac_verify = release_workflow[/name: Verify signature, notarization, and update feed[\s\S]{0,1800}/]
    expect(mac_verify).to include('test -x "$APP/Contents/Resources/cli/syrus-darwin-arm64"')
    expect(mac_verify).to include('test -x "$APP/Contents/Resources/cli/syrus-darwin-x64"')

    # Windows: the packaged resources dir (win-unpacked is what NSIS wraps)
    # must carry the x64 exe.
    windows_verify = release_workflow[/name: Verify signatures and update feed[\s\S]{0,1800}/]
    expect(windows_verify).to include("desktop/out/win-unpacked/resources/cli/syrus-win32-x64.exe")
    expect(windows_verify).to include("Bundled CLI missing")
  end

  it "release workflow verifies the signature, stapling, and stable download aliases" do
    expect(release_workflow).to include("codesign --verify --deep --strict")
    expect(release_workflow).to include("xcrun stapler validate")
    # One universal macOS build → one Syrus.dmg permalink (no Intel split);
    # Windows is x64-only → Syrus-Setup.exe.
    expect(release_workflow).to match(%r{"desktop/out/Syrus-\$VERSION-universal\.dmg" "\$RUNNER_TEMP/staged/Syrus\.dmg"})
    expect(release_workflow).not_to include("Syrus-Intel.dmg")
    expect(release_workflow).to match(%r{Syrus-Setup-\$VERSION-x64\.exe" "\$RUNNER_TEMP/staged/Syrus-Setup\.exe"})
    expect(release_workflow).not_to include("Syrus-Setup-arm64.exe")
    # Parsimony: macOS auto-update rides the .zip (+ blockmap) + latest-mac.yml;
    # the versioned dmg would be a byte-identical twin of Syrus.dmg, so it (and
    # its blockmap) is NOT staged. Don't reintroduce the blanket dmg/blockmap copy.
    expect(release_workflow).to match(%r{cp "desktop/out/Syrus-\$VERSION-universal\.zip"})
    expect(release_workflow).not_to include("cp desktop/out/Syrus-*.dmg")
    expect(release_workflow).not_to match(%r{cp desktop/out/\*\.blockmap})
  end

  it "ships CLI tarballs for Linux only (macOS/Windows get the CLI via the desktop app)" do
    cli = read(repo_root, "bin/release-cli")
    expect(cli).to include("linux/arm64")
    expect(cli).to include("linux/amd64")
    expect(cli).not_to include("darwin/")
  end

  it "deploys the website via a reusable workflow, callable standalone too" do
    workflow = YAML.safe_load(release_workflow)
    # The release's website step CALLS the shared workflow — no duplicated
    # deploy logic — so the site can also be updated without a release.
    expect(workflow.dig("jobs", "publish-website", "uses")).to eq("./.github/workflows/deploy-website.yml")

    deploy = read(repo_root, ".github/workflows/deploy-website.yml")
    triggers = YAML.safe_load(deploy)[true] # `on:` parses as the boolean key
    expect(triggers.keys).to include("workflow_call", "workflow_dispatch", "push")
    expect(deploy).to include("website/**") # push path filter
    # Still a documented stub until a real deploy target exists.
    expect(deploy).to include("Website deploy is a stub")
  end

  it "desktop CI covers typecheck, builds, and the installer's machine interface" do
    workflow = YAML.safe_load(ci_workflow)
    expect(workflow["jobs"].keys).to include("desktop", "installer")
    expect(ci_workflow).to include("bash -n install.sh")
    expect(ci_workflow).to include("jq -e")
  end

  it "documents the release runbook: one manual dispatch, signed, image in CI" do
    runbook = read(repo_root, "docs/releasing.md")
    # The runbook describes the manual dispatch pipeline, not a hand-tagged flow.
    expect(runbook).to include("workflow_dispatch").or include("Run workflow")
    expect(runbook).to include("release.yml")
    expect(runbook).to include("CSC_LINK")
    expect(runbook).to include("must be public")
    # The old "publish the image by hand before tagging" step is gone.
    expect(runbook).not_to match(/git tag vX\.Y\.Z && git push origin vX\.Y\.Z/)
  end
end

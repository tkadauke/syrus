# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "tmpdir"
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
  let(:promotion_workflow) { read(repo_root, ".github/workflows/promote-release-images.yml") }
  # The build/sign spine (build-backend, merge-backend, build-cli, build-mac)
  # lives in the reusable module both Release and Test build call; release.yml
  # is the thin caller that owns prepare + publish. Assertions about how a
  # component is built read the module; publish assertions read release.yml.
  let(:build_workflow) { read(repo_root, ".github/workflows/_build-app.yml") }
  let(:ci_workflow) { read(repo_root, ".github/workflows/desktop-ci.yml") }

  def run_release_version_compute(version:, force_lower: false, latest_tag: "v1.4.0")
    workflow = YAML.safe_load(release_workflow)
    script = workflow.dig("jobs", "prepare", "steps").find { |step| step["id"] == "compute" }.fetch("run")

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "desktop"))
      File.write(File.join(dir, "desktop/package.json"), JSON.generate(version: "0.0.0"))
      system("git", "init", "-q", chdir: dir, exception: true)
      system("git", "config", "user.email", "release-spec@example.com", chdir: dir, exception: true)
      system("git", "config", "user.name", "Release Spec", chdir: dir, exception: true)
      system("git", "add", "desktop/package.json", chdir: dir, exception: true)
      system("git", "commit", "-qm", "fixture", chdir: dir, exception: true)
      system("git", "tag", latest_tag, chdir: dir, exception: true)

      env = {
        "BUMP" => "patch",
        "OVERRIDE" => version,
        "FORCE_LOWER" => force_lower.to_s,
        "DRY" => "false",
        "REVIEW" => "false",
        "GITHUB_OUTPUT" => File.join(dir, "output"),
        "GITHUB_STEP_SUMMARY" => File.join(dir, "summary")
      }
      Open3.capture3(env, "bash", "-c", script, chdir: dir)
    end
  end

  it "keeps auto-update inert for unsigned dev builds, test runs, and the test channel" do
    expect(app_updates).to include("app.isPackaged &&")
    expect(app_updates).to include("!process.env.SYRUS_DISABLE_AUTO_UPDATE")
    # Only the STABLE channel auto-updates — a packaged local dev build (0.0.0,
    # the test channel) must not download the stable release over itself.
    expect(app_updates).to include("isStableChannel()")
    expect(app_updates).to include('resolveChannel({ env: process.env.SYRUS_CHANNEL, productName: app.getName(), version: app.getVersion() }) === "stable"')
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
    # publish-website calls deploy-website.yml (a reusable workflow that needs
    # pages + id-token); a called workflow can't exceed its caller's grants,
    # and missing grants are a parse-time startup_failure (even though the
    # job is skipped on dry runs). Least privilege: granted on the
    # publish-website JOB only — workflow-wide would hand OIDC minting to
    # every job.
    expect(workflow.dig("permissions", "pages")).to be_nil
    expect(workflow.dig("permissions", "id-token")).to be_nil
    pw_perms = workflow.dig("jobs", "publish-website", "permissions")
    expect(pw_perms).to eq("contents" => "read", "pages" => "write", "id-token" => "write")
    # One coherent pipeline: compute the version (prepare), build everything
    # through the shared reusable module (build), then a single publish job and
    # the website deploy. release.yml is thin — the build/sign jobs live in the
    # module it calls.
    expect(workflow["jobs"].keys).to include("prepare", "build", "publish", "publish-website")
    expect(workflow.dig("jobs", "build", "uses")).to eq("./.github/workflows/_build-app.yml")
    build_workflow_yaml = YAML.safe_load(build_workflow)
    expect(build_workflow_yaml["jobs"].keys).to include(
      "build-backend", "merge-backend", "build-cli", "build-mac"
    )
    # Atomic: publish waits for the whole build spine (the single `build` job)
    # and is skipped on a dry run, so a failure means nothing is tagged,
    # released, or promoted. A reusable job's `needs` covers every job inside it.
    expect(workflow.dig("jobs", "publish", "needs")).to include("build")
    expect(workflow.dig("jobs", "publish", "if")).to include("dry_run == 'false'")
    expect(workflow.dig("jobs", "publish-website", "if")).to include("dry_run == 'false'")
  end

  it "only releases reviewed main source and gates signing and publishing" do
    workflow = YAML.safe_load(release_workflow)
    build = YAML.safe_load(build_workflow)

    expect(workflow.dig("jobs", "prepare", "if")).to eq("github.ref == 'refs/heads/main'")
    expect(build.dig("jobs", "build-mac", "environment")).to eq("release-signing")
    expect(workflow.dig("jobs", "publish", "environment")).to eq("release-signing")
  end

  # Regression: the module's signing credentials were once left to the
  # release-signing environment alone, with no `secrets:` on the caller and no
  # `workflow_call.secrets` on the module. A reusable workflow sees NO secret it
  # has not declared -- entering an environment grants that environment's own
  # secrets and its protection rules, it is not a channel across the
  # workflow_call boundary -- so every signing secret resolved to the empty
  # string and build-mac died on its own "signing secrets present" guard. Both
  # halves have to line up, for both callers, or the first release run after a
  # change like that is the thing that discovers it.
  it "declares every secret the build module reads, and passes it from both callers" do
    build = YAML.safe_load(build_workflow)
    test_build = YAML.safe_load(read(repo_root, ".github/workflows/test-build.yml"))

    # GITHUB_TOKEN is ambient in every workflow; everything else must be
    # declared, or it is empty at runtime.
    referenced = build_workflow.scan(/secrets\.([A-Z0-9_]+)/).flatten.uniq - ["GITHUB_TOKEN"]
    declarations = build.dig(true, "workflow_call", "secrets")

    expect(referenced).not_to be_empty
    expect(declarations).to be_a(Hash), "the module must declare, under workflow_call.secrets, every secret it reads"
    expect(declarations.keys).to match_array(referenced)
    # Enumerated, never `secrets: inherit` -- the module reads these five and
    # nothing else the callers hold.
    declarations.each { |name, spec| expect(spec["required"]).to be(true), "#{name} must be required" }
    declared = declarations.keys

    [YAML.safe_load(release_workflow), test_build].each do |caller_workflow|
      passed = caller_workflow.dig("jobs", "build", "secrets")
      expect(passed).to be_a(Hash), "caller must pass the module's secrets explicitly"
      expect(passed.keys).to match_array(declared)
      declared.each { |name| expect(passed[name]).to eq("${{ secrets.#{name} }}") }
    end
  end

  # Regression: `xcrun stapler validate` and `spctl` are the only verification
  # assertions that leave the machine -- they look the notarization ticket up in
  # Apple's CloudKit -- so "The network connection was lost." reds a release
  # whose app is already built, signed, notarized and stapled. Retry them.
  describe "the macOS verification step's retry around Apple's notarization lookups" do
    # The `apple_check` helper, lifted out of the workflow and driven directly.
    # `sleep` is stubbed out so the backoff costs the suite nothing.
    def run_apple_check(script_body)
      step = YAML.safe_load(build_workflow).dig("jobs", "build-mac", "steps")
                 .find { |candidate| candidate["name"].to_s.start_with?("Verify signature") }
      helper = step.fetch("run")[/^apple_check\(\) \{\n.*?^\}\n/m]
      raise "apple_check helper not found in the verify step" if helper.nil?

      Dir.mktmpdir do |dir|
        path = File.join(dir, "check.sh")
        File.write(path, "set -euo pipefail\nsleep() { :; }\n#{helper}\n#{script_body}\n")
        out, status = Open3.capture2e("bash", path)
        [out, status.success?]
      end
    end

    it "passes a check that succeeds on the first try, without retrying" do
      out, ok = run_apple_check(<<~SH)
        attempts=0
        flaky() { attempts=$((attempts + 1)); return 0; }
        apple_check "stapler" flaky
        echo "attempts=$attempts"
      SH

      expect(ok).to be(true), out
      expect(out).to include("attempts=1")
      expect(out).not_to include("::warning::")
    end

    it "retries a flaky check and succeeds once Apple answers" do
      out, ok = run_apple_check(<<~SH)
        attempts=0
        flaky() { attempts=$((attempts + 1)); [ "$attempts" -ge 3 ]; }
        apple_check "stapler" flaky
        echo "attempts=$attempts"
      SH

      expect(ok).to be(true), out
      expect(out).to include("attempts=3")
      expect(out.scan("::warning::").length).to eq(2)
    end

    it "still fails the build when the check never passes" do
      out, ok = run_apple_check(<<~SH)
        attempts=0
        broken() { attempts=$((attempts + 1)); return 1; }
        apple_check "stapler" broken || echo "exited nonzero after $attempts"
      SH

      expect(ok).to be(true), out # the `|| echo` swallows it; the point is the message
      expect(out).to include("exited nonzero after 5")
      expect(out).to include("::error::stapler still failing after 5 attempts")
    end

    it "wraps both of the network-dependent assertions and no local one" do
      run = YAML.safe_load(build_workflow).dig("jobs", "build-mac", "steps")
                .find { |candidate| candidate["name"].to_s.start_with?("Verify signature") }.fetch("run")

      expect(run).to include(%(apple_check "spctl notarization assessment" spctl_notarized))
      expect(run).to include(%(apple_check "xcrun stapler validate" xcrun stapler validate "$APP"))
      # codesign is local: no network, no retry, and a failure there is real.
      expect(run).to match(/^codesign --verify --deep --strict/)
    end
  end

  it "release workflow only ships signed builds and STAGES them (never publishes mid-build)" do
    # Signing is a hard requirement — even a dry run signs (it's the fragile
    # part worth rehearsing). The macOS guard refuses to build without it, and
    # forceCodeSigning turns electron-builder's silent skip into a failure.
    expect(build_workflow.scan("A signed build is required").length).to be >= 1
    expect(build_workflow.scan("-c.forceCodeSigning=true").length).to be >= 1
    # The signed build/sign steps are NOT gated on a real run — dry runs sign
    # too. There is no unsigned dry-run build step anymore.
    expect(build_workflow).not_to include("Build unsigned (dry run)")
    # Build jobs stage artifacts — they never publish to the release directly
    # (only the atomic publish job does). So no build uses --publish always.
    expect(build_workflow).not_to include("--publish always")
    expect(build_workflow).to include("--publish never")
    # Credential preflights fail in seconds, not after a 15-minute build.
    expect(build_workflow).to include("Preflight: Apple signing credentials")
    # Notarization failures surface the developer log, and stapler runs on the
    # .app — the DMG container carries no ticket (Error 65 by design).
    expect(build_workflow).to include("Fetch notarytool developer log")
    expect(build_workflow).to match(/stapler validate "\$APP"/)
    expect(build_workflow).not_to match(/stapler validate "\$dmg"/)
    # Runaway builds must not burn the 6-hour default job timeout.
    workflow = YAML.safe_load(build_workflow)
    expect(workflow.dig("jobs", "build-mac", "timeout-minutes")).to be_a(Integer)
    expect(workflow.dig("jobs", "build-backend", "timeout-minutes")).to be_a(Integer)
    # Regression: 45 minutes killed an amd64 leg that had already pushed its
    # digest, skipping merge-backend and publish over an image that existed.
    # The two legs measured 46min / 40min on that run, so the timeout has to
    # stay clear of a working build; it is there to catch a hang.
    expect(workflow.dig("jobs", "build-backend", "timeout-minutes")).to be >= 60
  end

  it "release workflow builds each arch natively (no QEMU) and merges by digest" do
    # The backend build spine lives in the shared module.
    build = YAML.safe_load(build_workflow)
    release = YAML.safe_load(release_workflow)
    # build-backend is a per-arch matrix on native runners — amd64 on
    # ubuntu-latest, arm64 on ubuntu-24.04-arm — so NO QEMU emulation.
    expect(build_workflow).to include("ubuntu-24.04-arm")
    expect(build_workflow).not_to include("setup-qemu-action")
    expect(build.dig("jobs", "build-backend", "strategy", "matrix", "include")).to be_an(Array)
    # Each leg builds + integration-tests its own arch via bin/publish-image
    # --no-push (identical whether or not we push → both arches always
    # exercised), then push_image pushes that arch BY DIGEST. The tag/skip-tests
    # come from inputs, so the invocation is the args-array form.
    # The positional arg doubles as the baked SYRUS_VERSION — it must be the
    # APP-STYLE version so the in-app badge reads identically for app and
    # backend, never the registry tag.
    expect(build_workflow).to match(/args=\("\$VERSION" --no-push\)/)
    expect(build_workflow).to match(%r{bin/publish-image "\$\{args\[@\]\}"})
    expect(build_workflow).not_to include("--multi-arch") # QEMU path is gone from CI
    expect(build_workflow).to include("push-by-digest=true")
    # Per-arch cache refs so the two legs don't clobber each other's mode=max
    # cache. The module appends -<arch> to the caller's cache_ref_prefix; the
    # release caller passes the shared (non-test) buildcache prefix.
    expect(build_workflow).to include("${{ inputs.cache_ref_prefix }}-${{ matrix.arch }}")
    expect(release.dig("jobs", "build", "with", "cache_ref_prefix")).to eq("ghcr.io/tkadauke/syrus-backend:buildcache")
    # merge-backend assembles the digests into the versioned multi-arch tag; it's
    # gated on push_image, which the release caller ties to a real (non-dry) run.
    expect(build_workflow).to include("docker buildx imagetools create")
    expect(build_workflow).to match(/imagetools create -t "\$IMAGE:\$VERSION"/)
    expect(build.dig("jobs", "merge-backend", "if")).to eq("inputs.push_image")
    expect(release.dig("jobs", "build", "with", "push_image")).to eq("${{ needs.prepare.outputs.dry_run == 'false' }}")
    # ...and :latest is moved to :VERSION only in the atomic publish job, which
    # stays in release.yml.
    expect(release_workflow).to match(/imagetools create -t "\$IMAGE:latest" "\$IMAGE:\$VERSION"/)
    # The fat image still overflows the runner without freeing disk first.
    expect(build_workflow).to match(/Free disk space/)
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

  it "promotes latest images only after publishing a stable release" do
    workflow = YAML.safe_load(release_workflow)
    steps = workflow.dig("jobs", "publish", "steps")
    step_by_name = steps.to_h { |step| [step["name"], step] }
    publish_index = steps.index(step_by_name.fetch("Publish the release"))

    promotion_names = [
      "Move image :latest to the released version",
      "Move plugin images :latest to the released version"
    ]

    promotion_names.each do |name|
      promotion = step_by_name.fetch(name)

      expect(promotion.fetch("if")).to include("prerelease != 'true'")
      expect(promotion.fetch("if")).to include("review_notes != 'true'")
      expect(steps.index(promotion)).to be > publish_index
    end
  end

  it "promotes a stable draft's images when a maintainer publishes it" do
    workflow = YAML.safe_load(promotion_workflow)
    promotion = workflow.dig("jobs", "promote-images")

    expect(promotion_workflow).to include("types: [published]")
    expect(promotion.fetch("if")).to eq("github.event.release.prerelease == false")
    expect(promotion_workflow).to match(/RELEASE_TAG:.*release\.tag_name/)
    expect(promotion_workflow).to include('VERSION="${RELEASE_TAG#v}"')
    expect(promotion_workflow).to include('imagetools create -t "$IMAGE:latest" "$IMAGE:$VERSION"')
    expect(promotion_workflow).to include('imagetools create -t "$PLUGIN_IMAGE:latest" "$PLUGIN_IMAGE:$VERSION"')

    rollback = promotion_workflow[/name: Roll back image promotion on failure[\s\S]{0,900}/]
    expect(rollback).to include("if: failure()")
    expect(rollback).to include('imagetools create -t "$IMAGE:latest" "$IMAGE@$OLD_LATEST"')
    expect(rollback).to include('imagetools create -t "$plugin_image:latest" "$plugin_image@$old"')
    expect(workflow.dig("jobs", "publish-website", "needs")).to eq("promote-images")
  end

  it "release publish is near-atomic: draft release, then flip, with rollback" do
    # The release is flipped from draft before stable :latest pointers move,
    # and a failure rolls the release and pointers back — no half-published
    # state.
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
    # `npm version "$VERSION"` stamps the desktop build in the shared module.
    expect(build_workflow.scan(/npm --prefix desktop version "\$VERSION"/).length).to be >= 1
    # No push-to-main bump step: publish only tags + releases.
    expect(release_workflow).not_to include("Commit the version bump to main")
    expect(release_workflow).not_to match(/git push origin "HEAD:/)
    # The version/tag are attacker-influenceable (whoever can dispatch); they
    # reach run: bodies only via env, never inline ${{ }} interpolation — in the
    # thin release caller AND in the shared module that owns the build bodies.
    [release_workflow, build_workflow].each do |wf|
      run_bodies = wf.scan(/run: \|[\s\S]*?(?=\n      - |\n  [a-z]|\z)/)
      run_bodies.each do |body|
        expect(body).not_to match(/\$\{\{\s*needs\./)
        expect(body).not_to match(/\$\{\{\s*inputs\./)
      end
    end
  end

  it "rejects Docker-incompatible and stale explicit release versions before building" do
    workflow = YAML.safe_load(release_workflow)
    inputs = workflow.dig(true, "workflow_dispatch", "inputs")
    compute = workflow.dig("jobs", "prepare", "steps").find { |step| step["id"] == "compute" }

    expect(inputs.dig("force_lower", "default")).to eq(false)
    expect(compute.dig("env", "FORCE_LOWER")).to eq("${{ inputs.force_lower }}")
    expect(compute["run"]).to include('^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$')
    expect(compute["run"]).not_to include("[-+][0-9A-Za-z.-]+")

    docker_stdout, docker_stderr, docker_status = run_release_version_compute(version: "1.5.0+meta")
    expect(docker_status).not_to be_success
    expect(docker_stdout + docker_stderr).to include("build metadata with '+' is unsupported")

    lower_stdout, lower_stderr, lower_status = run_release_version_compute(version: "1.3.9")
    expect(lower_status).not_to be_success
    expect(lower_stdout + lower_stderr).to include("must be greater than latest stable tag '1.4.0'")
  end

  it "uses SemVer precedence for prerelease overrides and permits an explicit emergency override" do
    prerelease_stdout, prerelease_stderr, prerelease_status = run_release_version_compute(version: "1.4.0-beta.1")
    expect(prerelease_status).not_to be_success
    expect(prerelease_stdout + prerelease_stderr).to include("must be greater than latest stable tag '1.4.0'")

    _stdout, _stderr, higher_status = run_release_version_compute(version: "1.5.0-beta.1")
    expect(higher_status).to be_success

    _stdout, _stderr, forced_status = run_release_version_compute(version: "1.3.9", force_lower: true)
    expect(forced_status).to be_success
  end

  it "release workflow guarantees the bundled CLI: Go on both desktop runners, presence asserted" do
    # 0.1.1/0.1.2 shipped with NO Resources/cli: macos-15 has no Go, and
    # stage-cli.mjs exited 0 after wiping the staging dir, so every in-app
    # CLI/skill install died with ENOENT. Three layers now prevent it:
    # (1) stage-cli hard-fails under SYRUS_RELEASE_BUILD=1 (pinned in
    # cli_install_spec), (2) the desktop job pins the Go toolchain from
    # cli/go.mod — same source of truth as build-cli — and (3) the verify
    # steps assert the binaries are actually inside the packaged app.
    # The setup-go steps (build-cli + build-mac) live in the shared module.
    setup_go = build_workflow.scan(%r{uses: actions/setup-go@\S+\s+with:\s+go-version-file: cli/go\.mod})
    expect(setup_go.length).to be >= 2
    # setup-go's default cache expects go.sum at the repo root; ours is under
    # cli/, so every setup-go step must point the cache there or it caches
    # nothing (with a warning) on every release run.
    expect(build_workflow.scan("cache-dependency-path: cli/go.sum").length).to be >= 2

    mac_job = build_workflow[/^  build-mac:[\s\S]*\z/]
    expect(mac_job).to include("go-version-file: cli/go.mod")

    # Layer (1) only arms itself when the workflow declares a release build:
    # stage-cli's hard-fail and the DMG's release naming both key on
    # SYRUS_RELEASE_BUILD=1.
    expect(mac_job).to include('SYRUS_RELEASE_BUILD: "1"')

    # The mac build's retry-once loop must treat the stage-cli hard-fail as
    # deterministic (like a notarization "Invalid") — retrying a missing Go
    # toolchain just burns 90s and mislabels the failure as transient.
    mac_build_step = build_workflow[/name: Build, sign, and notarize[\s\S]{0,1800}/]
    expect(mac_build_step).to include("grep -qF 'stage-cli: Go toolchain not found'")

    # macOS: both darwin arches ride the universal app (ensureCliCurrent
    # installs the one matching the running arch), asserted executable.
    mac_verify = YAML.safe_load(build_workflow).dig("jobs", "build-mac", "steps")
                     .find { |step| step["name"].to_s.start_with?("Verify signature") }.fetch("run")
    expect(mac_verify).to include('test -x "$APP/Contents/Resources/cli/syrus-darwin-arm64"')
    expect(mac_verify).to include('test -x "$APP/Contents/Resources/cli/syrus-darwin-x64"')
  end

  it "release workflow verifies the signature, stapling, and stable download aliases" do
    # Verify + stage live in the shared module. The release feed staging is the
    # stage_update_feed=true branch (the release caller passes true).
    release_with = YAML.safe_load(release_workflow).dig("jobs", "build", "with")
    expect(release_with["stage_update_feed"]).to eq(true)
    expect(release_with["run_integration_tests"]).to eq(true)
    expect(build_workflow).to include("codesign --verify --deep --strict")
    expect(build_workflow).to include("xcrun stapler validate")
    # One universal macOS build → one Syrus.dmg permalink (no Intel split).
    # Filenames carry the channel's product name ($PRODUCT), which is "Syrus"
    # on the release (stable) caller.
    expect(build_workflow).to match(%r{"desktop/out/\$PRODUCT-\$VERSION-universal\.dmg" "\$RUNNER_TEMP/staged/\$PRODUCT\.dmg"})
    expect(build_workflow).not_to include("Syrus-Intel.dmg")
    # Parsimony: macOS auto-update rides the .zip (+ blockmap) + latest-mac.yml;
    # the versioned dmg would be a byte-identical twin of Syrus.dmg, so on the
    # release-feed path it is NOT staged under its versioned name. Don't
    # reintroduce the blanket dmg/blockmap copy.
    expect(build_workflow).to match(%r{cp "desktop/out/\$PRODUCT-\$VERSION-universal\.zip"})
    expect(build_workflow).not_to include("cp desktop/out/Syrus-*.dmg")
    expect(build_workflow).not_to match(%r{cp desktop/out/\*\.blockmap})
  end

  it "ships CLI tarballs for Linux only (macOS gets the CLI via the desktop app)" do
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
    expect(deploy).to include("actions/deploy-pages")
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

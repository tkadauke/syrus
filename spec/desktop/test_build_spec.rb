# frozen_string_literal: true

require "yaml"
require "spec_helper"

# The TEST BUILD pipeline (.github/workflows/test-build.yml). Its contract
# is the inverse of release.yml's: every component is DETERMINISTICALLY built —
# the backend image is pushed to GHCR under a collision-proof test tag, and the
# signed desktop app pins that exact tag — while publishing is structurally
# impossible (contents: read, no gh release, :latest untouched). The invariants
# here are the ones that would quietly turn a test build into a shadow release
# (or a broken artifact) if broken.
#
# test-build.yml is a THIN caller of the shared build spine: it computes the
# test identifiers (prepare) and calls the reusable _build-app.yml module with
# test parameters. The build/sign steps themselves live in the module, shared
# with release.yml — so assertions about HOW a component is built read the
# module, and assertions about the test-specific inputs read the thin caller.
RSpec.describe "desktop test-build pipeline" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:workflow_path) { File.join(repo_root, ".github/workflows/test-build.yml") }
  let(:workflow_text) { File.read(workflow_path, encoding: "UTF-8") }
  let(:workflow) { YAML.safe_load(workflow_text) }
  # The shared build spine both Release and Test build call.
  let(:build_path) { File.join(repo_root, ".github/workflows/_build-app.yml") }
  let(:build_text) { File.read(build_path, encoding: "UTF-8") }
  let(:build_yaml) { YAML.safe_load(build_text) }

  it "is workflow_dispatch-only, with a deliberately small input surface" do
    # `on:` parses as the boolean key true.
    triggers = workflow[true]
    expect(triggers.keys).to eq(["workflow_dispatch"])
    inputs = triggers.dig("workflow_dispatch", "inputs")
    expect(inputs.keys).to contain_exactly("run_integration_tests")
    expect(inputs.dig("run_integration_tests", "type")).to eq("boolean")
    expect(inputs.dig("run_integration_tests", "default")).to eq(true)
  end

  it "makes publishing structurally impossible: contents read-only, no release, no :latest" do
    # contents: read means creating a tag or GitHub Release cannot happen even
    # if a step tried — the strongest "never publishes" guarantee.
    expect(workflow.dig("permissions", "contents")).to eq("read")
    expect(workflow.dig("permissions", "packages")).to eq("write")
    # No release surface at all in the thin caller.
    expect(workflow_text).not_to include("gh release")
    expect(workflow_text).not_to include("--generate-notes")
    # The module tags both the sha-named primary and the version-named twin
    # (image_extra_tag); :latest never moves — not in the module, not here.
    expect(build_text).to include('docker buildx imagetools create -t "$IMAGE:$VERSION" ${VERSION_TAG:+-t "$IMAGE:$VERSION_TAG"}')
    expect(build_text).not_to match(/imagetools create[^\n]*:latest/)
    expect(workflow_text).not_to match(/imagetools create[^\n]*:latest/)
    # The thin caller passes the version-named twin as the extra tag.
    expect(workflow.dig("jobs", "build", "with", "image_extra_tag")).to eq("${{ needs.prepare.outputs.version_tag }}")
    # Thin caller: only prepare + the reusable build call. No publish jobs.
    expect(workflow["jobs"].keys).to contain_exactly("prepare", "build")
    # The build spine's jobs live in the shared module.
    expect(build_yaml["jobs"].keys).to contain_exactly(
      "build-backend", "merge-backend", "build-cli", "build-macos-worker", "build-mac"
    )
  end

  it "keeps test builds off the release concurrency group and supersedes stale runs" do
    expect(workflow.dig("concurrency", "group")).to include("test-build-")
    expect(workflow.dig("concurrency", "cancel-in-progress")).to eq(true)
  end

  it "guards the image tag and app version so they can never collide with a release" do
    # test-<short-sha> for the image; the guard step re-asserts the shape and
    # explicitly rejects `latest` and semver-looking tags.
    expect(workflow_text).to include('image_tag="test-$short_sha"')
    expect(workflow_text).to include('^test-[a-f0-9]{7,}$')
    expect(workflow_text).to include('if [ "$IMAGE_TAG" = "latest" ]')
    expect(workflow_text).to include('"$IMAGE_TAG" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]')
    # The version-named twin tag is guarded to the test- prefix too, so the
    # badge-consistent tag can also never collide with a release tag.
    expect(workflow_text).to include('version_tag="test-$app_version"')
    expect(workflow_text).to include('^test-[0-9]+\.[0-9]+\.[0-9]+-test\.[0-9]+$')
    # The installers carry a -test.<run-number> prerelease over the next
    # patch, so a test app can never be mistaken for a release. (The reverse
    # direction — a test install never auto-updating ONTO a release — is the
    # appUpdates.ts guard, pinned below.)
    expect(workflow_text).to include('-test.$GITHUB_RUN_NUMBER')
    expect(workflow_text).to include('^[0-9]+\.[0-9]+\.[0-9]+-test\.[0-9]+$')
    # The version base mirrors release.yml's prepare: the HIGHER of the newest
    # release tag and the committed desktop/package.json floor, so test builds
    # stay on the right release line during a planned major/minor bump.
    expect(workflow_text).to include(%q{pkg="$(node -p "require('./desktop/package.json').version")"})
    expect(workflow_text).to include(%q{base="$(printf '%s\n%s\n' "${latest_tag:-0.0.0}" "${pkg%%-*}" | sort -V | tail -1)"})
  end

  it "disarms auto-update in both directions" do
    # Direction 1: release installs never see a test build — nothing here is
    # published to the GitHub Releases feed (permissions + the stage_update_feed
    # input pin that below).
    # Direction 2: a test install never replaces ITSELF — a signed test build
    # still carries the baked-in GitHub feed (electron-builder writes
    # app-update.yml regardless of --publish never), and semver orders
    # X.Y.Z-test.N BELOW X.Y.Z, so an armed updater would swap the pinned
    # evaluation for the next published release. The app's updater guard
    # skips auto-update for -test. versions; the classifier's behavior is
    # covered by desktop/src/pinnedTestBuild.test.ts, the wiring is pinned
    # here.
    classifier = File.read(File.join(repo_root, "desktop/electron/pinnedTestBuild.ts"), encoding: "UTF-8")
    expect(classifier).to include('isPinnedTestBuild = (version: string): boolean => /-test\.\d+$/.test(version)')
    app_updates = File.read(File.join(repo_root, "desktop/electron/appUpdates.ts"), encoding: "UTF-8")
    expect(app_updates).to include('import { isPinnedTestBuild } from "./pinnedTestBuild.js"')
    expect(app_updates).to match(/updatesEnabled = \(\)[\s\S]{0,160}!isPinnedTestBuild\(app\.getVersion\(\)\)/)
    expect(File.exist?(File.join(repo_root, "desktop/src/pinnedTestBuild.test.ts"))).to be(true)
  end

  it "builds the backend natively per arch, always pushes by digest, and merges the test tag" do
    # Same native matrix as release.yml — amd64 on ubuntu-latest, arm64 on
    # ubuntu-24.04-arm, NO QEMU. All in the shared module.
    expect(build_text).to include("ubuntu-24.04-arm")
    expect(build_text).not_to include("setup-qemu-action")
    expect(build_yaml.dig("jobs", "build-backend", "strategy", "matrix", "include")).to be_an(Array)
    # The build goes through bin/publish-image --no-push (integration gate
    # included; run_integration_tests=false maps to its --skip-tests flag).
    expect(build_text).to match(/args=\("\$VERSION" --no-push\)/)
    # Badge consistency (user-reported): the backend must BAKE the app-style
    # version (X.Y.Z-test.N), not the sha tag, and both build sites take it
    # from inputs.version — "app 0.1.4-test.3 · backend 0.1.4-test.3".
    backend_build = build_text[/- name: Build \+ integration-test[\s\S]{0,2400}?bin\/publish-image/]
    expect(backend_build).to match(/VERSION: \$\{\{ inputs\.version \}\}/)
    digest_push = build_text[/- name: Push \$\{\{ matrix\.arch \}\} by digest[\s\S]{0,2400}?SYRUS_VERSION=\$VERSION/]
    expect(digest_push).to match(/VERSION: \$\{\{ inputs\.version \}\}/)
    expect(build_text).to include("--skip-tests")
    # The by-digest push and the manifest merge are gated on the push_image
    # input, not a dry_run flag — and the test caller ALWAYS passes true, so
    # uploading the image is the deterministic outcome this workflow exists for.
    expect(build_text).to include("push-by-digest=true")
    expect(build_text).not_to match(/if:.*dry_run/)
    expect(workflow.dig("jobs", "build", "with", "push_image")).to eq(true)
    push_step = build_yaml.dig("jobs", "build-backend", "steps").find { |s| s["name"] == "Push ${{ matrix.arch }} by digest" }
    expect(push_step["if"]).to eq("inputs.push_image")
    expect(build_yaml.dig("jobs", "merge-backend", "if")).to eq("inputs.push_image")
    # The merged manifest is verified pullable through the shared helper.
    expect(build_text).to include('syrus_verify_pushed "$IMAGE" "$VERSION"')
    # Test builds write their OWN registry cache refs. bin/publish-image's
    # --cache-to mode=max REPLACES the tag it writes, so pointing a test build
    # at release.yml's shared buildcache-<arch> tags would let a divergent
    # test branch evict the warm cache the next real release depends on. The
    # module appends -<arch> to whatever cache_ref_prefix the caller passes;
    # the test caller passes the buildcache-test prefix.
    expect(workflow.dig("jobs", "build", "with", "cache_ref_prefix")).to eq("ghcr.io/tkadauke/syrus-backend:buildcache-test")
    expect(build_text.scan("${{ inputs.cache_ref_prefix }}-${{ matrix.arch }}").size).to eq(2)
  end

  it "derives SYRUS_BUILT_AT from the source, never the wall clock, in both build and push" do
    # Same deterministic expression as a release (HEAD's committer date, UTC)
    # in the publish-image build step AND the by-digest push step, so both
    # arch images and the desktop stamp agree on one instant. Shared module.
    git_stamp = %q{SYRUS_BUILT_AT="$(TZ=UTC git show -s --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' HEAD)"}
    expect(build_text.scan(git_stamp).size).to eq(2)
    expect(build_text).not_to include('SYRUS_BUILT_AT="$(date')
    expect(build_text).not_to include('SYRUS_BUILT_AT=${SYRUS_BUILT_AT:-}')
    # The push rebuild must stay a cache hit of the tested build — identical
    # build args (the lockstep rule, pinned in docker_image_scripts_spec).
    expect(build_text).to include('--build-arg "GIT_SHA=$(git rev-parse --short HEAD)"')
    expect(build_text).to include('--build-arg "SYRUS_VERSION=$VERSION"')
    expect(build_text).to include('--build-arg "SYRUS_BUILT_AT=$SYRUS_BUILT_AT"')
  end

  it "pins the pushed test image into the desktop app and verifies the pin" do
    # The module reads SYRUS_BACKEND_IMAGE from the backend_image_pin input in
    # the desktop build step — overriding stage-backend-assets.mjs's
    # version-derived pin, which would otherwise be :<app_version>, a tag that
    # never exists. The test caller pins the VERSION-NAMED tag so the in-app
    # badge reads identically for app and backend (the module bakes the
    # app-style version as SYRUS_VERSION: app 0.1.4-test.1 · backend
    # 0.1.4-test.1); the version-named tag is registry addressing.
    expect(build_text.scan("SYRUS_BACKEND_IMAGE: ${{ inputs.backend_image_pin }}").size).to eq(1)
    expect(workflow.dig("jobs", "build", "with", "backend_image_pin")).to eq(
      "ghcr.io/tkadauke/syrus-backend:${{ needs.prepare.outputs.version_tag }}"
    )
    # Desktop builds in parallel with the backend — the pin is a string, not a
    # pull; merge-backend pushes the image concurrently and it exists by run
    # completion. (Parallelism is pinned in its own example.)
    # ...and each verify step asserts the sealed manifest actually carries it.
    expect(build_text).to include('grep -qF "\"image\": \"$BACKEND_IMAGE\"" "$APP/Contents/Resources/backend/manifest.json"')
  end

  it "signs test builds exactly like a release (guards, preflights, forced signing)" do
    # All shared with the release through the module.
    expect(build_text.scan("A signed build is required").length).to be >= 1
    expect(build_text.scan("-c.forceCodeSigning=true").length).to be >= 1
    expect(build_text).to include("Preflight: Apple signing credentials")
    expect(build_text).to include("xcrun stapler validate")
    # SYRUS_RELEASE_BUILD arms stage-cli's hard-fail and release DMG naming in
    # the desktop job, and Go is pinned so the hard-fail never fires.
    expect(build_text.scan('SYRUS_RELEASE_BUILD: "1"').size).to eq(1)
    setup_go = build_text.scan(%r{uses: actions/setup-go@\S+\s+with:\s+go-version-file: cli/go\.mod})
    expect(setup_go.length).to eq(2)
    expect(build_text.scan("cache-dependency-path: cli/go.sum").size).to eq(2)
    expect(build_text).to include("grep -qF 'stage-cli: Go toolchain not found'")
    # Stage only — nothing ever publishes from a build.
    expect(build_text).to include("--publish never")
    expect(build_text).not_to include("--publish always")
  end

  it "cross-compiles and stages the CLI tarballs like a real release" do
    # The Linux CLI is a shippable component too: bin/release-cli runs
    # `go test ./...`, cross-compiles linux/amd64 + arm64 tarballs, and writes
    # SHA256SUMS-cli.txt. A test build must prove it builds. Shared module.
    expect(build_yaml.dig("jobs", "build-cli", "steps")).to be_an(Array)
    expect(build_text).to match(%r{run: bin/release-cli "\$TAG"})
    expect(build_text).to include("TAG: v${{ inputs.version }}")
    expect(build_text).to include("path: dist/releases/v${{ inputs.version }}/cli/")
    # No input gate — release.yml's build-cli is unconditional, so is the module's.
    expect(build_yaml.dig("jobs", "build-cli", "if")).to be_nil
    # The test caller feeds the CLI tag off the -test. app version.
    expect(workflow.dig("jobs", "build", "with", "version")).to eq("${{ needs.prepare.outputs.app_version }}")
  end

  it "uploads versioned artifacts to the run only — no permalinks, no update feed" do
    # The versioned .dmg / CLI tarballs land as workflow-run artifacts with a
    # 14-day retention and hard-fail if the build produced
    # nothing. Retention + hard-fail are module-level; the test caller sets 14.
    expect(workflow.dig("jobs", "build", "with", "artifact_retention_days")).to eq(14)
    expect(workflow.dig("jobs", "build", "with", "artifact_prefix")).to eq("test-staged")
    expect(build_text.scan("if-no-files-found: error").size).to be >= 2
    expect(build_text).to include("retention-days: ${{ inputs.artifact_retention_days }}")
    # A test build stages ONLY the versioned DMG (the else branch of the
    # stage_update_feed gate). Filenames carry the channel product name — the
    # test caller passes channel: test, so $PRODUCT is "Syrus Test" at runtime.
    expect(build_text).to match(%r{cp "desktop/out/\$PRODUCT-\$VERSION-universal\.dmg" "\$RUNNER_TEMP/staged/"})
    # The channel-feeding staging (stable-name aliases + latest-mac.yml /
    # .blockmap) is gated on stage_update_feed, which the test
    # caller turns OFF — so a test build never feeds the update channel.
    expect(workflow.dig("jobs", "build", "with", "stage_update_feed")).to eq(false)
    # …and the module's guard has the right polarity: the permalink aliases +
    # update-feed files are copied ONLY inside the STAGE_FEED=true branch.
    expect(build_text.scan("STAGE_FEED: ${{ inputs.stage_update_feed }}").size).to eq(1)
    mac_stage = build_text[/if \[ "\$STAGE_FEED" = "true" \]; then[\s\S]{0,700}?else/]
    expect(mac_stage).to include("latest-mac.yml")
    expect(mac_stage).to include('staged/$PRODUCT.dmg"')

    # The failure-diagnostics artifact must stay OUTSIDE the caller's
    # `<prefix>-*` namespace: release's publish downloads `pattern: staged-*`
    # with merge-multiple and attaches every file to the PUBLIC Release, and
    # artifacts persist across re-run attempts.
    expect(build_text).to include("name: mac-diagnostics-${{ inputs.artifact_prefix }}")
    expect(build_text).not_to include("name: ${{ inputs.artifact_prefix }}-mac-diagnostics")
  end

  it "never inlines the computed tag/version into shell bodies" do
    # Same rule as release.yml: attacker-influenceable values reach run:
    # bodies only via env, never inline ${{ }} interpolation. Walk the parsed
    # YAML of BOTH the thin caller and the shared module so EVERY run: value is
    # covered — the module owns the build bodies that handle the tags/version.
    run_bodies = [workflow, build_yaml].flat_map do |wf|
      wf["jobs"].values.flat_map { |job| Array(job["steps"]).map { |step| step["run"] } }
    end.compact
    expect(run_bodies.length).to be >= 15 # every step across both files, not a lucky subset
    run_bodies.each do |body|
      expect(body).not_to match(/\$\{\{\s*needs\./)
      expect(body).not_to match(/\$\{\{\s*inputs\./)
    end
  end

  it "documents the test-build runbook next to the release one" do
    runbook = File.read(File.join(repo_root, "docs/releasing.md"), encoding: "UTF-8")
    expect(runbook).to include("test-build.yml")
    expect(runbook).to include("gh workflow run test-build.yml --ref")
    expect(runbook).to include("test-staged-mac")
    expect(runbook).to include("test-staged-cli")
    # The tag scheme and retention are the operator-facing contract.
    expect(runbook).to match(/test-<short-sha>|test-<sha>/)
    expect(runbook).to include("14 days")
  end

  it "builds desktop in parallel with the backend (no merge-backend gate)" do
    # The manifest pin is a string match, not a docker pull, so the desktop
    # job never needs the image to exist yet — gating it on merge-backend
    # serialized ~5 min of pure waiting. In the module build-mac carries NO
    # needs, so it starts immediately alongside build-backend; only merge-backend
    # waits on the backend. Same posture as release.yml.
    expect(build_yaml.dig("jobs", "build-mac", "needs")).to be_nil
    expect(build_yaml.dig("jobs", "merge-backend", "needs")).to eq("build-backend")
  end
end

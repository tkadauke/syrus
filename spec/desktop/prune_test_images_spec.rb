# frozen_string_literal: true

require "yaml"
require "spec_helper"

# Retention for the nightly test build's GHCR images. Everything asserted here
# is a safety property: this workflow deletes published images, and a GHCR
# "version" is a digest, so one wrong candidate takes every tag on that digest
# with it. These are the guards that stop a prune from eating a release.
RSpec.describe "prune test images workflow" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:workflow_text) { File.read(File.join(repo_root, ".github/workflows/prune-test-images.yml"), encoding: "UTF-8") }
  let(:workflow) { YAML.safe_load(workflow_text) }
  let(:step) { workflow.dig("jobs", "prune", "steps").find { |s| s["run"].to_s.include?("versions") } }

  it "runs nightly after the test build, and on demand" do
    triggers = workflow[true] # `on:` parses as the boolean key true
    expect(triggers.keys).to contain_exactly("schedule", "workflow_dispatch")

    prune_hour = Array(triggers["schedule"]).first["cron"][/\A0 (\d+) /, 1].to_i
    build_hour = YAML.safe_load(
      File.read(File.join(repo_root, ".github/workflows/test-build.yml"), encoding: "UTF-8")
    )[true]["schedule"].first["cron"][/\A0 (\d+) /, 1].to_i

    # Pruning before the night's push would delete nothing and then let that
    # night's images sit an extra day; it must trail the build.
    expect(prune_hour).to be > build_hour
  end

  it "keeps a 14 day window" do
    expect(step.dig("env", "RETENTION_DAYS")).to eq("14")
  end

  # `buildcache-test-amd64` and `buildcache-test-arm64` are real tags on
  # syrus-backend. A substring match would delete them and silently destroy
  # cross-run build caching, so the match has to be anchored.
  it "matches test tags by prefix, never by substring" do
    expect(step["run"]).to include('all(startswith("test-"))')
    expect(step["run"]).not_to match(/contains\(\s*"test"/)
  end

  # A digest tagged both `test-…` and `latest` exists today: the plugin images
  # were retagged from :latest, so the two share a version. Deleting on "has a
  # test tag" would have taken :latest and the release tag with it.
  it "only deletes versions whose tags are all test tags" do
    expect(step["run"]).to include("all(")
    expect(step["run"]).not_to include("any(")
  end

  # On a multi-arch push the per-arch children are untagged but referenced by
  # the index; deleting them breaks the published image.
  it "skips untagged versions" do
    expect(step["run"]).to include("($tags | length) > 0")
  end

  # `inputs` is empty on a schedule, so a bare inputs.dry_run would be "" --
  # falsy by accident rather than by decision.
  it "never lets a scheduled prune inherit the manual dry-run default" do
    dry_run = step.dig("env", "DRY_RUN").to_s
    expect(dry_run).to include("github.event_name == 'workflow_dispatch'")
    expect(dry_run).not_to eq("${{ inputs.dry_run }}")
    expect(workflow.dig(true, "workflow_dispatch", "inputs", "dry_run", "default")).to be(true)
  end

  # `gh api --jq` takes one filter and no --arg; passing the cutoff that way
  # exits "accepts 1 arg(s)" and, with stderr swallowed, is indistinguishable
  # from "nothing to prune".
  it "passes the cutoff through real jq rather than gh api --jq" do
    expect(step["run"]).to include('jq -r --arg cutoff "$cutoff"')
    expect(step["run"]).not_to include("--jq --arg")
  end

  it "cannot write to the repository" do
    expect(workflow["permissions"]).to eq({ "contents" => "read" })
  end
end

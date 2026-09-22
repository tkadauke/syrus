# frozen_string_literal: true

require "yaml"
require "rails_helper"

# The Playwright e2e/ suite (bin/test-e2e) never ran in CI before this
# workflow existed -- these are the invariants that keep it that way:
# path-scoped so it doesn't burn CI budget on unrelated changes (website/,
# desktop/, cli/-only PRs), and still actually running the full suite
# (not a narrowed subset) once it does trigger.
RSpec.describe "e2e CI workflow" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:workflow_path) { File.join(repo_root, ".github/workflows/e2e-ci.yml") }
  let(:workflow_text) { File.read(workflow_path, encoding: "UTF-8") }
  let(:workflow) { YAML.safe_load(workflow_text) }

  it "exists and parses as a single e2e job" do
    expect(File).to exist(workflow_path)
    expect(workflow.dig("jobs", "e2e")).to be_present
  end

  it "triggers on pull_request and push-to-main, both scoped to app-facing paths" do
    triggers = workflow[true] # `on:` parses as the boolean key true
    expect(triggers.keys).to contain_exactly("pull_request", "push")
    expect(triggers.dig("push", "branches")).to eq(["main"])

    %w[pull_request push].each do |trigger|
      paths = triggers.dig(trigger, "paths")
      expect(paths).to include("app/**", "e2e/**", "plugins/**", "bin/test-e2e")
      # Desktop and website changes have their own dedicated CI workflows;
      # an e2e-only path list keeps this workflow from firing on every PR.
      expect(paths).not_to include("desktop/**", "website/**")
    end
  end

  it "cancels superseded runs on the same ref" do
    expect(workflow.dig("concurrency", "group")).to eq("e2e-${{ github.ref }}")
    expect(workflow.dig("concurrency", "cancel-in-progress")).to be(true)
  end

  it "gives the suite real headroom and runs the whole thing, not a narrowed slice" do
    job = workflow.dig("jobs", "e2e")
    expect(job["timeout-minutes"]).to be >= 30

    run_steps = Array(job["steps"]).map { |step| step["run"] }.compact
    expect(run_steps).to include("npm ci")
    expect(run_steps).to include("bin/test-e2e")
    expect(run_steps.join("\n")).not_to match(/bin\/test-e2e --project=/)
  end

  it "installs Chromium's OS-level dependencies before bin/test-e2e installs the browser itself" do
    # bin/test-e2e installs the Playwright browser binaries (idempotent), but
    # not the system shared libraries Chromium needs -- the worker image gets
    # those via Dockerfile's `--with-deps`, a bare ubuntu-latest runner does not.
    run_steps = Array(workflow.dig("jobs", "e2e", "steps")).map { |step| step["run"] }.compact
    deps_index = run_steps.index { |body| body.include?("playwright install-deps") }
    suite_index = run_steps.index { |body| body.strip == "bin/test-e2e" }
    expect(deps_index).not_to be_nil
    expect(suite_index).not_to be_nil
    expect(deps_index).to be < suite_index
  end
end

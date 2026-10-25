# frozen_string_literal: true

require "yaml"
require "rails_helper"

RSpec.describe "CI workflow" do
  let(:workflow_path) { Rails.root.join(".github/workflows/ci.yml") }
  let(:workflow) { YAML.safe_load(workflow_path.read) }

  it "gives RSpec the same headroom as the CI grader" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "rspec-ci" }

    expect(workflow.dig("jobs", "rspec", "timeout-minutes")).to eq(grader.timeout_minutes)
  end

  it "installs Node dependencies before running RSpec" do
    steps = workflow.dig("jobs", "rspec", "steps")
    run_steps = steps.filter_map { |step| step["run"] }

    expect(run_steps.index("npm ci")).to be < run_steps.index("bin/rspec-ci")
    expect(steps).to include(
      a_hash_including(
        "uses" => "actions/setup-node@v7",
        "with" => a_hash_including("node-version" => 22)
      )
    )
  end
end

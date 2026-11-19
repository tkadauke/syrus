# frozen_string_literal: true

require "yaml"
require "rails_helper"

RSpec.describe "CI workflow" do
  let(:workflow_path) { Rails.root.join(".github/workflows/ci.yml") }
  let(:workflow) { YAML.safe_load(workflow_path.read) }

  it "installs Node dependencies before running RSpec" do
    steps = workflow.dig("jobs", "rspec", "steps")
    run_steps = steps.filter_map { |step| step["run"] }

    # Each RSpec shard runs `bin/rspec-ci $(bin/rspec-shard-files ...)`.
    rspec_step_index = run_steps.index { |command| command.start_with?("bin/rspec-ci ") }
    expect(rspec_step_index).to be_present
    expect(run_steps.index("npm ci")).to be < rspec_step_index
    expect(steps).to include(
      a_hash_including(
        "uses" => "actions/setup-node@v7",
        "with" => a_hash_including("node-version" => 22)
      )
    )
  end

  it "leaves enough time for the complete React coverage suite" do
    expect(workflow.dig("jobs", "react", "timeout-minutes")).to be >= 30
  end

  it "keeps the React suite on its validated runner image" do
    expect(workflow.dig("jobs", "react", "runs-on")).to eq("ubuntu-24.04")
  end
end

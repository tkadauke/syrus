# frozen_string_literal: true

require "yaml"
require "rails_helper"

RSpec.describe "CI workflow" do
  let(:workflow_path) { Rails.root.join(".github/workflows/ci.yml") }
  let(:workflow) { YAML.safe_load(workflow_path.read) }

  it "installs frontend dependencies before running specs that load the Vite config" do
    steps = workflow.dig("jobs", "rspec", "steps")
    actions = steps.filter_map { |step| step["uses"] }
    commands = steps.filter_map { |step| step["run"] }

    expect(actions).to include("actions/setup-node@v7")
    expect(commands).to include("npm ci", "bin/rspec-ci")
    expect(commands.index("npm ci")).to be < commands.index("bin/rspec-ci")
  end
end

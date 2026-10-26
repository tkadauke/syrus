# frozen_string_literal: true

require "yaml"
require "rails_helper"

RSpec.describe "CI workflow" do
  let(:workflow) do
    YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
  end

  it "installs JavaScript dependencies before configuration specs load Vite" do
    steps = workflow.dig("jobs", "rspec", "steps")
    node_setup_index = steps.index { |step| step["uses"] == "actions/setup-node@v7" }
    npm_install_index = steps.index { |step| step["run"] == "npm ci" }
    rspec_index = steps.index { |step| step["run"] == "bin/rspec-ci" }

    expect(node_setup_index).not_to be_nil
    expect(npm_install_index).to be_between(node_setup_index + 1, rspec_index - 1)
  end
end

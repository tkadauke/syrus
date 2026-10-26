require "rails_helper"
require "yaml"

RSpec.describe "CI workflow" do
  let(:workflow) do
    YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
  end

  it "installs Node dependencies before running specs that load frontend config" do
    steps = workflow.dig("jobs", "rspec", "steps")
    install_index = steps.index { |step| step["run"] == "npm ci" }
    rspec_index = steps.index { |step| step["run"] == "bin/rspec-ci" }

    expect(steps).to include(include("uses" => "actions/setup-node@v7"))
    expect(install_index).to be < rspec_index
  end
end

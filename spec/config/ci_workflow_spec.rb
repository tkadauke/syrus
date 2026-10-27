require "rails_helper"
require "yaml"

RSpec.describe "CI workflow" do
  let(:workflow) do
    YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
  end

  it "installs JavaScript dependencies before running RSpec" do
    steps = workflow.dig("jobs", "rspec", "steps")
    install_index = steps.index { |step| step["run"] == "npm ci" }
    rspec_index = steps.index { |step| step["run"] == "bin/rspec-ci" }

    expect(install_index).to be < rspec_index
  end
end

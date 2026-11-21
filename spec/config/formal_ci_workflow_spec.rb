require "rails_helper"

RSpec.describe "Formal CI workflow" do
  let(:workflow) { YAML.load_file(Rails.root.join(".github/workflows/formal-ci.yml")) }
  let(:steps) { workflow.fetch("jobs").fetch("lean").fetch("steps") }

  it "runs for changes to the Lean models on pull requests and main" do
    triggers = workflow.fetch(true) { workflow.fetch("on") }

    expect(triggers.dig("pull_request", "paths")).to include("formal/**")
    expect(triggers.dig("push", "paths")).to include("formal/**")
    expect(triggers.dig("push", "branches")).to eq([ "main" ])
  end

  it "checks every proof with lake from the formal project" do
    expect(workflow.dig("jobs", "lean", "defaults", "run", "working-directory")).to eq("formal")
    expect(steps.map { |step| step["run"].to_s }).to include("lake build")
  end

  it "fails on unfinished proofs, which lake only warns about" do
    guard = steps.find { |step| step["name"] == "No unfinished proofs" }

    expect(guard).to be_present
    expect(guard.fetch("run")).to include("sorry").and include("admit").and include("exit 1")
  end
end

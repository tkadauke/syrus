require "rails_helper"

RSpec.describe ChatTemplates::Triage do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  it "builds an open-issues triage prompt with the expected instructions" do
    prompt = described_class.new(repository: repository, target: "issues").to_s

    expect(prompt).to include("Triage acme/widgets's open issues.")
    expect(prompt).to include("duplicate or near-duplicate issues")
    expect(prompt).to include("Suggest labels or closures")
    expect(prompt).to include("propose_issue")
    expect(prompt).not_to include("stale pull requests")
  end

  it "builds an open-PR triage prompt" do
    prompt = described_class.new(repository: repository, target: "prs").to_s

    expect(prompt).to include("Triage acme/widgets's open PRs.")
    expect(prompt).to include("stale pull requests")
    expect(prompt).to include("draft pull requests")
    expect(prompt).not_to include("duplicate or near-duplicate issues")
  end

  it "rejects unknown targets" do
    expect {
      described_class.new(repository: repository, target: "branches")
    }.to raise_error(ArgumentError, /target must be issues or prs/)
  end
end

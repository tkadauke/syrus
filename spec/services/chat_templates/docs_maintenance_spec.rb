require "rails_helper"

RSpec.describe ChatTemplates::DocsMaintenance do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  it "points the chat agent at roadmap and plans maintenance" do
    prompt = described_class.new(repository: repository).to_s

    expect(prompt).to include("ROADMAP.md")
    expect(prompt).to include("docs/plans/")
    expect(prompt).to include("docs/plans/complete/")
    expect(prompt).to include("recent commits")
    expect(prompt).to include("closed pull requests")
    expect(prompt).to include("closed Syrus Jobs")
    expect(prompt).to include("shipped")
    expect(prompt).to include("stale")
    expect(prompt).to include("ROADMAP.md sections that are out of date")
    expect(prompt).to include("propose_issue")
    expect(prompt).to include("Do not edit ROADMAP.md or docs/plans/*")
  end
end

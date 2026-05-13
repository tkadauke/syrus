require "rails_helper"

RSpec.describe ChatTemplates::Walkthrough do
  let(:repo) { repository(owner: "acme", name: "widgets") }

  it "uses the guided-tour first user message" do
    template = described_class.new(repository: repo)

    expect(template.user_message).to eq(
      "Give me a guided tour of this repository. Cover architecture, the main services, the dispatcher loop, and any non-obvious conventions. Cite file:line for everything."
    )
  end

  it "frames the system message as a forgiving walkthrough prompt" do
    out = described_class.new(repository: repo).system_message

    expect(out).to include("repository walkthrough mode for acme/widgets")
    expect(out).to include("avoid assuming this\nis a Rails app, a Syrus repo")
    expect(out).to include("If a file or directory\nis missing, say what you checked and move on.")
  end

  it "includes the expected reading list as a hint to the agent" do
    out = described_class.new(repository: repo).system_message

    expect(out).to include("- README.md")
    expect(out).to include("- ARCHITECTURE.md")
    expect(out).to include("- CLAUDE.md")
    expect(out).to include("- AGENTS.md")
    expect(out).to include("- db/schema.rb")
    expect(out).to include("- app/services")
    expect(out).to include("- app/jobs")
    expect(out).to include("Use the reading list as a hint, not a contract.")
  end
end

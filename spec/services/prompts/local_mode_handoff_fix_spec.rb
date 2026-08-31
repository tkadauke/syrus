require "rails_helper"

RSpec.describe Prompts::LocalModeHandoffFix do
  it "frames a fresh workflow-agent repair for a Local Mode handoff branch" do
    issue = Struct.new(:title, :body).new("Add terminal polish", "Make the terminal panel clearer.")

    output = described_class.new(
      issue: issue,
      repo_slug: "acme/widgets",
      branch_name: "syrus/local-mode-99",
      recent_commits: [ { sha: "abcdef123456", subject: "Polish terminal panel" } ]
    ).to_s

    expect(output).to include("Local Mode handoff repair")
    expect(output).to include("fresh workflow agent owns the repair")
    expect(output).to include("Do not route work back to the originating Local Mode chat")
    expect(output).to include("Add terminal polish")
    expect(output).to include("syrus/local-mode-99")
    expect(output).to include("abcdef1 Polish terminal panel")
    expect(output).to include(Prompts::GitSafety::TEXT)
    expect(output).to include(Prompts::ShellCommandExecutionContract::TEXT)
  end
end

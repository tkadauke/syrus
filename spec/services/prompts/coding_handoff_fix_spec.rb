require "rails_helper"

RSpec.describe Prompts::CodingHandoffFix do
  it "frames a fresh workflow-agent repair for a committed handoff branch" do
    issue = Struct.new(:title, :body).new("Add terminal polish", "Make the terminal panel clearer.")

    output = described_class.new(
      issue: issue,
      repo_slug: "acme/widgets",
      branch_name: "syrus/chat-1-handoff-99",
      handoff_snapshot: {
        "source_branch" => "chat/work",
        "handoff_branch" => "syrus/chat-1-handoff-99",
        "head_sha" => "abc123456789",
        "base_sha" => "def456789012",
        "changed_files" => [ "app/models/job.rb", "spec/models/job_spec.rb" ],
        "captured_at" => "2026-07-30T12:00:00Z"
      },
      recent_commits: [ { sha: "abcdef123456", subject: "Polish terminal panel" } ]
    ).to_s

    expect(output).to include("Coding Mode handoff repair")
    expect(output).to include("fresh workflow agent owns the repair")
    expect(output).to include("Do not route work back to the original chat")
    expect(output).to include("Add terminal polish")
    expect(output).to include("chat/work")
    expect(output).to include("abc123456789")
    expect(output).to include("- app/models/job.rb")
    expect(output).to include("abcdef1 Polish terminal panel")
    expect(output).to include(Prompts::GitSafety::TEXT)
  end
end

require "rails_helper"

RSpec.describe Prompts::LandingFix do
  it "frames the final merge-readiness pass for the current PR branch" do
    issue = Struct.new(:title, :body).new("Keep dashboard honest", "Run the final checks after rebasing.")

    output = described_class.new(
      issue: issue,
      pr_number: 123,
      repo_slug: "acme/widgets",
      branch_name: "syrus/issue-42-9",
      recent_commits: [ { sha: "abcdef123456", subject: "Fix dashboard state" } ]
    ).to_s

    expect(output).to include("final merge-readiness pass")
    expect(output).to include("acme/widgets#123")
    expect(output).to include("syrus/issue-42-9")
    expect(output).to include("Keep dashboard honest")
    expect(output).to include("abcdef1 Fix dashboard state")
    expect(output).to include("If there is no concrete problem to fix, make no code changes.")
    expect(output).to include(Prompts::GitSafety::TEXT)
  end

  it "includes Epic context before recent commits when supplied" do
    issue = Struct.new(:title, :body).new("Keep dashboard honest", "Run the final checks after rebasing.")
    epic = instance_double(
      Epic,
      slug: "EPIC-70",
      title: "Syrus CLI and test planning",
      description: "Do not turn a final fix into a broader Epic implementation."
    )

    output = described_class.new(
      issue: issue,
      pr_number: 123,
      repo_slug: "acme/widgets",
      branch_name: "syrus/issue-42-9",
      recent_commits: [ { sha: "abcdef123456", subject: "Fix dashboard state" } ],
      epic: epic
    ).to_s

    expect(output).to include("EPIC-70: Syrus CLI and test planning")
    expect(output).to include("Do not implement the entire Epic")
    expect(output.index("EPIC-70")).to be < output.index("Recent commits")
  end

  it "caps an oversized issue body" do
    issue = Struct.new(:title, :body).new("Large issue", "i" * (described_class::MAX_ISSUE_BODY_BYTES + 1))
    output = described_class.new(issue: issue, pr_number: 1, repo_slug: "acme/widgets", branch_name: "topic").to_s

    expect(output).to include("[issue body truncated, 1 more bytes]")
  end
end

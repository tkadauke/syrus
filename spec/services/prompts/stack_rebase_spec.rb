require "rails_helper"

RSpec.describe Prompts::StackRebase do
  it "names each stack branch, base, job, and PR in order" do
    out = described_class.new(
      repo_slug: "acme/widgets",
      stack_entries: [
        { "job_id" => 12, "branch_name" => "syrus/issue-12-1", "base_branch" => "main", "pr_number" => 34 },
        { "job_id" => 13, "branch_name" => "syrus/issue-13-1", "base_branch" => "syrus/issue-12-1", "pr_number" => nil }
      ]
    ).to_s

    expect(out).to include("stack rebase")
    expect(out).to include("acme/widgets")
    expect(out).to include("1. JOB-12: `syrus/issue-12-1` onto `main` (PR #34)")
    expect(out).to include("2. JOB-13: `syrus/issue-13-1` onto `syrus/issue-12-1` (no PR number)")
  end

  it "uses the shared rebase skill instructions and git safety contract" do
    out = described_class.new(
      repo_slug: "acme/widgets",
      stack_entries: [
        { "job_id" => 12, "branch_name" => "syrus/issue-12-1", "base_branch" => "main", "pr_number" => 34 }
      ]
    ).to_s

    expect(out).to include(Prompts::GitSafety::TEXT)
    expect(out).to match(/git rebase/)
    expect(out).to match(/Do NOT make functional changes/i)
    expect(out).to include("Leave every listed branch as a local branch")
  end
end

require "rails_helper"

RSpec.describe Prompts::Rebase do
  it "names the PR, the branch, and the base in the prompt" do
    out = described_class.new(
      repo_slug: "acme/widgets",
      branch_name: "syrus/issue-42-1",
      base_branch: "main",
      pr_number: 7
    ).to_s

    expect(out).to include("acme/widgets#7")
    expect(out).to include("syrus/issue-42-1")
    expect(out).to include("main")
  end

  it "tells the agent to rebase, not to make functional changes, and not to push (Syrus does that)" do
    out = described_class.new(repo_slug: "acme/widgets", branch_name: "b", base_branch: "main", pr_number: 1).to_s

    # Branch names live in the context paragraph; rebase instruction uses
    # a generic placeholder in the skill file — the agent substitutes from context.
    expect(out).to include("main")
    expect(out).to match(/git rebase/)
    expect(out).to match(/Do NOT make functional changes/i)
    expect(out).to match(/force-push/)
  end

  it "tells the agent to abort rather than push a half-rebased branch" do
    out = described_class.new(repo_slug: "x/y", branch_name: "b", base_branch: "main", pr_number: 1).to_s
    expect(out).to match(/git rebase --abort/)
  end
end

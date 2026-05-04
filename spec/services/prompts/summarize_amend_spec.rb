require "rails_helper"

RSpec.describe Prompts::SummarizeAmend do
  let(:out) { described_class.new.to_s }

  it "frames this as a follow-up commit, not a new PR" do
    expect(out).to match(/follow-up\s+commit/im)
    expect(out).to match(/PR.+already exists/im)
  end

  it "tells the agent to call submit_summary with all three fields" do
    expect(out).to include("submit_summary")
    expect(out).to include("pr_title")
    expect(out).to include("pr_body")
    expect(out).to include("summary")
  end

  it "instructs the agent not to make new commits" do
    expect(out).to match(/Don't make new commits/i)
  end

  it "describes pr_title as a commit message for this revision, not the whole PR" do
    expect(out).to match(/what changed \*in this revision\*/i)
  end

  it "does not append the SubmitSummaryInstructions block (it has its own framing)" do
    expect(out).not_to include(Prompts::SubmitSummaryInstructions::TEXT)
  end
end

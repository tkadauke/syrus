require "rails_helper"

RSpec.describe Prompts::Summarize do
  let(:out) { described_class.new.to_s }

  it "references the prior implement step" do
    expect(out).to match(/implement\*\* step/i)
  end

  it "tells the agent to call submit_summary with all three fields" do
    expect(out).to include("submit_summary")
    expect(out).to include("pr_title")
    expect(out).to include("pr_body")
    expect(out).to include("summary")
  end

  it "instructs the agent not to make additional commits" do
    expect(out).to match(/Don't make additional commits/i)
  end

  it "instructs the agent not to re-read files" do
    expect(out).to match(/Don't\s+re-read files/im)
  end

  it "describes pr_title as imperative mood, 50-72 chars" do
    expect(out).to include("50–72 chars")
    expect(out).to match(/imperative mood/)
  end
end

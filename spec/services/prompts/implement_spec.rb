require "rails_helper"

RSpec.describe Prompts::Implement do
  let(:issue) { Struct.new(:title, :body).new("Add greeting helper", "We need a helper to greet users.") }

  it "leads with the issue title and body" do
    out = described_class.new(issue: issue).to_s
    expect(out).to start_with("Add greeting helper\n\nWe need a helper to greet users.")
  end

  it "strips leading/trailing whitespace from the combined title+body" do
    padded = Struct.new(:title, :body).new("  Add greeting  ", "  body text  ")
    out = described_class.new(issue: padded).to_s
    expect(out).to start_with("Add greeting  \n\n  body text")
  end

  it "handles a nil body gracefully" do
    bodyless = Struct.new(:title, :body).new("Just a title", nil)
    out = described_class.new(issue: bodyless).to_s
    expect(out).to include("Just a title")
  end

  it "includes the git safety block" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include(Prompts::GitSafety::TEXT)
  end

  it "appends the phased-execution note telling the agent NOT to call submit_summary" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include(Prompts::Implement::STEP_NOTE)
    expect(out).to match(/DO NOT\s+call `submit_summary`/m)
  end

  it "does NOT append the SubmitSummaryInstructions block" do
    out = described_class.new(issue: issue).to_s
    expect(out).not_to include(Prompts::SubmitSummaryInstructions::TEXT)
    expect(out).not_to match(/CALL THE `submit_summary` MCP TOOL/)
  end
end

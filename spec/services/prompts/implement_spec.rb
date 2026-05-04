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

  it "includes the phased-execution note telling the agent NOT to call submit_summary" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include("Phased execution note: you're running the **implement** step")
    expect(out).to match(/DO NOT\s+call `submit_summary`/m)
  end

  it "does NOT append the SubmitSummaryInstructions block" do
    out = described_class.new(issue: issue).to_s
    expect(out).not_to include(Prompts::SubmitSummaryInstructions::TEXT)
    expect(out).not_to match(/CALL THE `submit_summary` MCP TOOL/)
  end

  describe "replay_context" do
    it "is omitted when not provided" do
      out = described_class.new(issue: issue).to_s
      expect(out).not_to include("Additional context from the operator")
    end

    it "is omitted when blank" do
      out = described_class.new(issue: issue, replay_context: "   ").to_s
      expect(out).not_to include("Additional context from the operator")
    end

    it "is injected between the issue content and the git safety block when present" do
      out = described_class.new(issue: issue, replay_context: "Please fix the failing tests.").to_s
      issue_pos   = out.index("Add greeting helper")
      context_pos = out.index("Additional context from the operator")
      safety_pos  = out.index(Prompts::GitSafety::TEXT)
      step_pos    = out.index("Phased execution note: you're running the **implement** step")
      expect(context_pos).to be > issue_pos
      expect(safety_pos).to be > context_pos
      expect(step_pos).to be > safety_pos
      expect(out).to include("Please fix the failing tests.")
    end
  end
end

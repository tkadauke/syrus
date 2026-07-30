require "rails_helper"

RSpec.describe Prompts::Implement do
  let(:issue) { Struct.new(:title, :body).new("Add greeting helper", "We need a helper to greet users.") }

  it "leads with labeled issue title and original body sections" do
    out = described_class.new(issue: issue).to_s
    expect(out).to start_with(
      "Issue title:\n\nAdd greeting helper\n\nOriginal issue body:\n\nWe need a helper to greet users."
    )
  end

  it "strips leading/trailing whitespace from the combined title+body" do
    padded = Struct.new(:title, :body).new("  Add greeting  ", "  body text  ")
    out = described_class.new(issue: padded).to_s
    expect(out).to start_with("Issue title:\n\n  Add greeting  \n\nOriginal issue body:\n\n  body text")
  end

  it "handles a nil body gracefully" do
    bodyless = Struct.new(:title, :body).new("Just a title", nil)
    out = described_class.new(issue: bodyless).to_s
    expect(out).to include("Just a title")
    expect(out).to include("Original issue body:\n\n(No issue body provided.)")
  end

  it "includes the git safety block" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include(Prompts::GitSafety::TEXT)
  end

  it "explains Syrus and .syrus.yml setup in the skill prompt" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include("Syrus is the automation harness")
    expect(out).to include("`.syrus.yml`")
    expect(out).to include("prepare:")
    expect(out).to include("auto-detects one setup command")
  end

  it "explains when to use the read-only live-state tool" do
    out = described_class.new(issue: issue).to_s
    expect(out).to include("read_live_state")
    expect(out).to include("current Job, Workflow, Run, queue, PR, or related chat state")
    expect(out).to include("Do not use it to mutate jobs or queues")
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

  describe "simple mode context" do
    it "prepends the simple-mode agent guidance when simple mode is enabled" do
      allow(AppSetting).to receive(:simple?).and_return(true)

      out = described_class.new(issue: issue).to_s

      expect(out).to start_with(Prompts::SimpleModeAgentContext::TEXT)
      expect(out).to include("ask one focused clarifying question")
      expect(out).to include("Use the Syrus memory tools liberally")
      expect(out).to include("Always write unit tests")
    end

    it "omits the simple-mode agent guidance when advanced mode is enabled" do
      allow(AppSetting).to receive(:simple?).and_return(false)

      out = described_class.new(issue: issue).to_s

      expect(out).to start_with("Issue title:")
      expect(out).not_to include(Prompts::SimpleModeAgentContext::TEXT)
    end
  end

  describe "issue comments" do
    it "omits the comments section when there are no comments" do
      out = described_class.new(issue: issue, issue_comments: []).to_s
      expect(out).not_to include("Subsequent issue comments")
    end

    it "renders serialized issue comments after the original body in provided order" do
      comments = [
        { "author" => "octavia", "body" => "Actually prefer a command object.", "created_at" => "2026-05-01T10:00:00Z" },
        { "author" => "lucius", "body" => "Keep the public method name.", "created_at" => "2026-05-01T11:00:00Z" }
      ]

      out = described_class.new(issue: issue, issue_comments: comments).to_s

      body_pos = out.index("Original issue body")
      comments_pos = out.index("Subsequent issue comments")
      first_pos = out.index("Comment 1 by @octavia")
      second_pos = out.index("Comment 2 by @lucius")
      safety_pos = out.index(Prompts::GitSafety::TEXT)

      expect(comments_pos).to be > body_pos
      expect(first_pos).to be > comments_pos
      expect(second_pos).to be > first_pos
      expect(safety_pos).to be > second_pos
      expect(out).to include("Actually prefer a command object.")
      expect(out).to include("Keep the public method name.")
    end
  end

  describe "injected_context" do
    it "appends injected strings to the prompt arguments" do
      out = described_class.new(
        issue: issue,
        injected_context: [ "Plugin says: check the schema.", "Also verify this edge case." ]
      ).to_s
      expect(out).to include("Plugin says: check the schema.")
      expect(out).to include("Also verify this edge case.")
    end

    it "omits nothing extra when injected_context is empty" do
      out_with    = described_class.new(issue: issue, injected_context: [ "extra" ]).to_s
      out_without = described_class.new(issue: issue).to_s
      expect(out_with).to include("extra")
      expect(out_without).not_to include("extra")
    end

    it "appears before the git safety block" do
      out = described_class.new(issue: issue, injected_context: [ "Plugin hint." ]).to_s
      hint_pos   = out.index("Plugin hint.")
      safety_pos = out.index(Prompts::GitSafety::TEXT)
      expect(hint_pos).to be < safety_pos
    end
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

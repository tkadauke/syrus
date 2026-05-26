require "rails_helper"

RSpec.describe Prompts::PrFeedback do
  let(:issue) { Struct.new(:title, :body).new("Add greeting", "We need a greeting helper.") }

  let(:user_login) { Struct.new(:login).new("reviewer") }

  let(:conversation) do
    Struct.new(:user, :body, :created_at).new(
      user_login, "Could you also handle empty strings?", Time.parse("2026-05-02 04:35:00 UTC")
    )
  end

  let(:inline) do
    Struct.new(:user, :body, :created_at, :path, :line, :diff_hunk).new(
      user_login,
      "This breaks when name is nil — interpolation gives \"Hello, !\"",
      Time.parse("2026-05-02 04:38:00 UTC"),
      "lib/greet.rb", 5,
      "@@ -1,5 +1,7 @@\n class Greeter\n   def greet(name = nil)\n+    \"Hello, #{nil}!\"\n+  end\n end"
    )
  end

  it "frames the issue, then each comment block, then the closing instruction" do
    out = described_class.new(issue: issue, comments: [ conversation, inline ]).to_s

    expect(out).to start_with("Original issue: Add greeting")
    expect(out).to include("We need a greeting helper.")
    expect(out).to include("PR review thread")
    expect(out).to include("Address each piece of feedback marked [NEW].")
    expect(out).to include("Make commits to the current branch.")
  end

  it "tags new comments with [NEW] and leaves prior comments untagged" do
    out = described_class.new(
      issue: issue,
      comments: [ conversation, inline ],
      cutoff: Time.parse("2026-05-02 04:36:00 UTC")
    ).to_s

    # conversation (04:35) is before the cutoff — context only.
    expect(out).to include("[Conversation comment from @reviewer at 2026-05-02 04:35:00 UTC]")
    expect(out).not_to include("[NEW] [Conversation comment from @reviewer at 2026-05-02 04:35:00 UTC]")

    # inline (04:38) is after the cutoff — actionable.
    expect(out).to include("[NEW] [Inline comment from @reviewer on lib/greet.rb:5]")
  end

  it "renders prior agent summaries when supplied" do
    out = described_class.new(
      issue: issue,
      comments: [ conversation ],
      prior_summaries: [ "Round-1 summary: tightened the docstring.", "Round-2 summary: added empty-string guard." ]
    ).to_s

    expect(out).to include("What you've done on this PR in previous review rounds")
    expect(out).to include("Round 1:")
    expect(out).to include("tightened the docstring")
    expect(out).to include("Round 2:")
    expect(out).to include("empty-string guard")
  end

  it "renders recent commits when supplied" do
    out = described_class.new(
      issue: issue,
      comments: [ conversation ],
      recent_commits: [
        { sha: "abc1234def", subject: "Address review feedback: empty-string handling" },
        { sha: "abc0000def", subject: "Initial implementation" }
      ]
    ).to_s

    expect(out).to include("Recent commits on the working branch")
    expect(out).to include("abc1234 Address review feedback")
    expect(out).to include("abc0000 Initial implementation")
  end

  it "appends the submit_summary instruction so follow-up runs also volunteer PR copy" do
    out = described_class.new(issue: issue, comments: [ conversation ]).to_s

    expect(out).to include("CALL THE `submit_summary` MCP TOOL")
    expect(out).to end_with(Prompts::SubmitSummaryInstructions::TEXT)
  end

  it "renders inline comments with path:line + indented diff_hunk" do
    out = described_class.new(issue: issue, comments: [ inline ]).to_s

    expect(out).to include("[Inline comment from @reviewer on lib/greet.rb:5]")
    expect(out).to include("Context:")
    expect(out).to include("  @@ -1,5 +1,7 @@")  # diff_hunk indented by 2
    expect(out).to include("Comment:\nThis breaks when name is nil")
  end

  it "renders conversation comments without code context" do
    out = described_class.new(issue: issue, comments: [ conversation ]).to_s

    expect(out).to include("[Conversation comment from @reviewer at 2026-05-02 04:35:00 UTC]")
    expect(out).to include("Could you also handle empty strings?")
    expect(out).not_to include("Context:")  # only inline comments get a Context section
  end

  it "preserves caller-supplied ordering (composer doesn't sort)" do
    earliest_first = described_class.new(issue: issue, comments: [ conversation, inline ]).to_s
    inline_first   = described_class.new(issue: issue, comments: [ inline, conversation ]).to_s

    expect(earliest_first.index("Could you also")).to be < earliest_first.index("This breaks when")
    expect(inline_first.index("This breaks when")).to be < inline_first.index("Could you also")
  end
end

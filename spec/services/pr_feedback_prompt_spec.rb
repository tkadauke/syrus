require "rails_helper"

RSpec.describe PrFeedbackPrompt do
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
    expect(out).to include("Reviewer feedback received since the last commit:")
    expect(out).to end_with("Address each piece of feedback. Make commits to the current branch.")
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

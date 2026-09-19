require "rails_helper"

RSpec.describe Prompts::ChatFeedback do
  let(:issue) { Struct.new(:title, :body).new("Add greeting", "We need a greeting helper.") }

  it "frames the issue, then the operator feedback, then the closing instruction" do
    out = described_class.new(issue: issue, feedback: "Please also handle nil names.").to_s

    expect(out).to start_with("Original issue: Add greeting")
    expect(out).to include("We need a greeting helper.")
    expect(out).to include("Operator feedback from Syrus Chat:")
    expect(out).to include("Please also handle nil names.")
    expect(out).to include("Address the operator feedback from Syrus Chat.")
    expect(out).to include("Make commits to the current branch.")
  end

  it "renders prior agent summaries when supplied" do
    out = described_class.new(
      issue: issue,
      feedback: "Tighten the copy.",
      prior_summaries: [ "Round-1 summary: added the greeting helper." ]
    ).to_s

    expect(out).to include("What you've done on this PR in previous feedback rounds")
    expect(out).to include("Round 1:")
    expect(out).to include("added the greeting helper")
  end

  it "renders recent commits when supplied" do
    out = described_class.new(
      issue: issue,
      feedback: "Tighten the copy.",
      recent_commits: [ { sha: "abc1234def", subject: "Address chat feedback" } ]
    ).to_s

    expect(out).to include("Recent commits on the working branch")
    expect(out).to include("abc1234 Address chat feedback")
  end

  it "includes Epic context before the feedback section when supplied" do
    epic = instance_double(
      Epic,
      slug: "EPIC-70",
      title: "Syrus CLI and test planning",
      description: "Keep follow-up work aligned with the CLI track."
    )

    out = described_class.new(issue: issue, feedback: "Tighten the copy.", epic: epic).to_s

    expect(out).to include("EPIC-70: Syrus CLI and test planning")
    expect(out.index("EPIC-70")).to be < out.index("Operator feedback from Syrus Chat")
  end

  it "appends the submit_summary instruction so follow-up runs also volunteer PR copy" do
    out = described_class.new(issue: issue, feedback: "Tighten the copy.").to_s

    expect(out).to include("CALL THE `submit_summary` MCP TOOL")
    expect(out).to end_with(Prompts::SubmitSummaryInstructions::TEXT)
  end

  it "renders anchored diff comments when supplied" do
    out = described_class.new(
      issue: issue,
      feedback: "Tighten the copy.",
      diff_comments: [
        { "path" => "lib/greet.rb", "line" => 5, "side" => "right", "diff_hunk" => "@@ -1,3 +1,3 @@", "body" => "Handle nil here." }
      ]
    ).to_s

    expect(out).to include("Anchored diff comments:")
    expect(out).to include("[lib/greet.rb:5 right]")
    expect(out).to include("Handle nil here.")
  end

  describe "memory context" do
    it "includes memory context before the directives section when the store has some" do
      user = Factories.user
      repository = Factories.repository(user: user)
      # What the store renders is the store's business; the composition order
      # is core's.
      allow(Syrus::Memory).to receive(:prompt_context)
        .with(user: user, repository_ids: [ repository.id ])
        .and_return("# Memory: feedback (7)\nAlways include regression coverage.")

      out = described_class.new(
        issue: issue,
        feedback: "Tighten the copy.",
        user: user,
        repository_ids: [ repository.id ]
      ).to_s

      expect(out).to include("Always include regression coverage.")
      expect(out.index("# Memory: feedback (7)")).to be < out.index("Address the operator feedback from Syrus Chat.")
    end

    it "omits the memory context section when no user is supplied" do
      out = described_class.new(issue: issue, feedback: "Tighten the copy.").to_s

      expect(out).not_to include("# Memory:")
    end
  end

  describe "injected_context" do
    it "is omitted when not provided" do
      out = described_class.new(issue: issue, feedback: "Tighten the copy.").to_s
      expect(out).not_to include("plugin-injected")
    end

    it "includes injected text in the rendered output" do
      out = described_class.new(
        issue: issue,
        feedback: "Tighten the copy.",
        injected_context: [ "plugin-injected hint" ]
      ).to_s
      expect(out).to include("plugin-injected hint")
    end
  end
end

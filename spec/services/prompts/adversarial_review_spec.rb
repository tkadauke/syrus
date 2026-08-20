require "rails_helper"

RSpec.describe Prompts::AdversarialReview do
  let(:issue) { Struct.new(:title, :body).new("Fix the auth bug", "It breaks on nil users.") }
  let(:diff) { "diff --git a/auth.rb b/auth.rb\n+return if user.nil?\n" }

  subject(:prompt) do
    described_class.new(
      issue: issue,
      diff: diff,
      prior_findings: prior_findings,
      workflow_kind: workflow_kind,
      feedback_context: feedback_context,
      criteria: criteria
    ).to_s
  end

  let(:prior_findings) { [] }
  let(:workflow_kind) { nil }
  let(:feedback_context) { nil }
  let(:criteria) { [] }

  it "includes independence instruction" do
    expect(prompt).to include("independent reviewer")
  end

  it "includes the job title and body" do
    expect(prompt).to include("Fix the auth bug")
    expect(prompt).to include("It breaks on nil users.")
  end

  it "includes a changed-file manifest instead of the full diff body" do
    expect(prompt).to include("Changed files from the latest succeeded implement step")
    expect(prompt).to include("auth.rb")
    expect(prompt).to include("git diff <base>...HEAD -- <path>")
    expect(prompt).not_to include("return if user.nil?")
  end

  context "with generated asset diffs" do
    let(:diff) do
      [
        "diff --git a/app/models/user.rb b/app/models/user.rb\n+def active? = true\n",
        "diff --git a/app/assets/builds/spa.js b/app/assets/builds/spa.js\n+#{'x' * 200_000}\n",
        "diff --git a/app/assets/builds/spa.js.map b/app/assets/builds/spa.js.map\n+#{'y' * 200_000}\n"
      ].join("\n")
    end

    it "lists generated assets without inlining their diff contents" do
      expect(prompt).to include("app/models/user.rb")
      expect(prompt).to include("app/assets/builds/spa.js")
      expect(prompt).to include("app/assets/builds/spa.js.map")
      expect(prompt).to include("generated artifacts as validation targets")
      expect(prompt).not_to include("def active? = true")
      expect(prompt).not_to include("x" * 1_000)
      expect(prompt.bytesize).to be < 10.kilobytes
    end
  end

  context "with a single huge source diff" do
    let(:diff) { "diff --git a/app/models/user.rb b/app/models/user.rb\n+#{'x' * 200_000}\n" }

    it "does not inline huge source diffs" do
      expect(prompt).to include("app/models/user.rb")
      expect(prompt).not_to include("x" * 1_000)
      expect(prompt.bytesize).to be < 10.kilobytes
    end
  end

  it "labels the diff as from an implement step by default" do
    expect(prompt).to include("implement step")
    expect(prompt).not_to include("respond step")
  end

  it "includes submit_adversarial_review tool instructions" do
    expect(prompt).to include("submit_adversarial_review")
    expect(prompt).to include("exact name shown in your tool list")
  end

  context "with criteria" do
    let(:criteria) { [ "Verify all endpoints enforce authentication", "No internal state in errors" ] }

    it "includes the pay-particular-attention section" do
      expect(prompt).to include("pay particular attention")
    end

    it "lists each criterion" do
      expect(prompt).to include("- Verify all endpoints enforce authentication")
      expect(prompt).to include("- No internal state in errors")
    end
  end

  context "without criteria" do
    let(:criteria) { [] }

    it "does not include the pay-particular-attention section" do
      expect(prompt).not_to include("pay particular attention")
    end
  end

  context "with prior findings" do
    let(:prior_findings) do
      [{ "iteration" => 1, "verdict" => "needs_work", "critique" => "Missing test for nil input." }]
    end

    it "renders prior findings" do
      expect(prompt).to include("Iteration 1")
      expect(prompt).to include("Missing test for nil input.")
    end
  end

  context "with workflow_kind: 'pr_comment'" do
    let(:workflow_kind) { "pr_comment" }

    it "notes this is a PR comment feedback workflow" do
      expect(prompt).to include("PR comment feedback workflow")
    end

    it "labels the diff as from a respond step" do
      expect(prompt).to include("respond step")
    end

    it "does not include feedback history when feedback_context is blank" do
      expect(prompt).not_to include("PR comments being addressed")
    end

    context "with feedback_context" do
      let(:feedback_context) { "@alice: Please add error handling.\n\n@bob: Also fix the typo." }

      it "includes the PR feedback history section" do
        expect(prompt).to include("PR comments being addressed")
        expect(prompt).to include("@alice: Please add error handling.")
        expect(prompt).to include("@bob: Also fix the typo.")
      end
    end
  end

  context "with workflow_kind: 'chat_feedback'" do
    let(:workflow_kind) { "chat_feedback" }

    it "notes this is a chat feedback workflow" do
      expect(prompt).to include("chat feedback workflow")
    end

    it "labels the diff as from a respond step" do
      expect(prompt).to include("respond step")
    end

    context "with feedback_context" do
      let(:feedback_context) { "Please refactor the helper method into its own class." }

      it "includes the chat feedback history section" do
        expect(prompt).to include("Chat feedback being addressed")
        expect(prompt).to include("Please refactor the helper method into its own class.")
      end
    end
  end

  context "with workflow_kind: 'initial'" do
    let(:workflow_kind) { "initial" }

    it "does not include a feedback workflow note" do
      expect(prompt).not_to include("feedback workflow")
    end

    it "labels the diff as from an implement step" do
      expect(prompt).to include("implement step")
    end
  end
end

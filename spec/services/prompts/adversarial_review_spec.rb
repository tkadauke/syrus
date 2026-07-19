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
      feedback_context: feedback_context
    ).to_s
  end

  let(:prior_findings) { [] }
  let(:workflow_kind) { nil }
  let(:feedback_context) { nil }

  it "includes independence instruction" do
    expect(prompt).to include("independent reviewer")
  end

  it "includes the job title and body" do
    expect(prompt).to include("Fix the auth bug")
    expect(prompt).to include("It breaks on nil users.")
  end

  it "includes the diff" do
    expect(prompt).to include("return if user.nil?")
  end

  it "labels the diff as from an implement step by default" do
    expect(prompt).to include("implement step")
    expect(prompt).not_to include("respond step")
  end

  it "includes submit_adversarial_review tool instructions" do
    expect(prompt).to include("submit_adversarial_review")
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

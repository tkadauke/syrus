require "rails_helper"

RSpec.describe Prompts::VisualReview do
  let(:issue) { Struct.new(:title, :body).new("Add a dashboard banner", "Show a banner on the dashboard.") }
  let(:diff) { "diff --git a/app/views/dashboard/show.html.erb b/app/views/dashboard/show.html.erb\n+<div class=\"banner\">New</div>\n" }

  subject(:prompt) do
    described_class.new(
      issue: issue,
      diff: diff,
      prior_findings: prior_findings,
      workflow_kind: workflow_kind,
      feedback_context: feedback_context,
      test_plan_recommended: test_plan_recommended,
      test_plan_reason: test_plan_reason,
      seed_notes: seed_notes
    ).to_s
  end

  let(:prior_findings) { [] }
  let(:workflow_kind) { nil }
  let(:feedback_context) { nil }
  let(:test_plan_recommended) { nil }
  let(:test_plan_reason) { nil }
  let(:seed_notes) { nil }

  it "includes independence instruction" do
    expect(prompt).to include("independent visual QA reviewer")
  end

  it "includes the job title and body" do
    expect(prompt).to include("Add a dashboard banner")
    expect(prompt).to include("Show a banner on the dashboard.")
  end

  it "includes the diff" do
    expect(prompt).to include('<div class="banner">New</div>')
  end

  it "labels the diff as from an implement step by default" do
    expect(prompt).to include("implement step")
    expect(prompt).not_to include("respond step")
  end

  it "includes submit_visual_review tool instructions" do
    expect(prompt).to include("submit_visual_review")
    expect(prompt).to include("exact name shown in your tool list")
  end

  it "describes the go/no-go, start_preview, browser, screenshot, and stop_preview workflow" do
    expect(prompt).to include("start_preview")
    expect(prompt).to include("stop_preview")
    expect(prompt).to include("verdict \"skipped\"")
  end

  it "does not include a test-plan hint section by default" do
    expect(prompt).not_to include("recommended running visual review")
    expect(prompt).not_to include("did NOT recommend")
  end

  it "does not include a seed notes section by default" do
    expect(prompt).not_to include("seed notes")
  end

  context "with the implementer recommending visual review" do
    let(:test_plan_recommended) { true }
    let(:test_plan_reason) { "Added a new banner to the dashboard header." }

    it "includes the recommendation and reason as a hint, not a directive" do
      expect(prompt).to include("recommended running visual review")
      expect(prompt).to include("Added a new banner to the dashboard header.")
      expect(prompt).to include("Treat this as a hint, not a directive")
    end
  end

  context "with the implementer recommending against visual review" do
    let(:test_plan_recommended) { false }
    let(:test_plan_reason) { "Backend-only refactor." }

    it "includes the negative recommendation" do
      expect(prompt).to include("did NOT recommend running visual review")
      expect(prompt).to include("Backend-only refactor.")
    end
  end

  context "with seed_notes" do
    let(:seed_notes) { "Log in as demo@example.com / password to reach the dashboard." }

    it "includes the seed notes section" do
      expect(prompt).to include("Log in as demo@example.com / password to reach the dashboard.")
    end
  end

  context "with prior findings" do
    let(:prior_findings) do
      [ { "iteration" => 1, "verdict" => "needs_work", "critique" => "The banner overlaps the nav." } ]
    end

    it "renders prior findings" do
      expect(prompt).to include("Iteration 1")
      expect(prompt).to include("The banner overlaps the nav.")
    end
  end

  context "with no prior findings" do
    it "notes there are none" do
      expect(prompt).to include("Prior visual review findings: none.")
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
      let(:feedback_context) { "@alice: The banner overlaps the nav on mobile." }

      it "includes the PR feedback history section" do
        expect(prompt).to include("PR comments being addressed")
        expect(prompt).to include("@alice: The banner overlaps the nav on mobile.")
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
      let(:feedback_context) { "Please make the banner dismissible." }

      it "includes the chat feedback history section" do
        expect(prompt).to include("Chat feedback being addressed")
        expect(prompt).to include("Please make the banner dismissible.")
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

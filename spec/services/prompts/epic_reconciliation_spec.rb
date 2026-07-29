require "rails_helper"

RSpec.describe Prompts::EpicReconciliation do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic)       { Factories.epic(user: user, repository: repository, title: "Unified Auth System") }

  # Two sibling jobs: one with a PR, one without.
  let(:job_with_pr) do
    j = Factories.job_record(user: user, repository: repository, issue_title: "Implement OAuth login")
    j.update_columns(pr_number: 201)
    j.reload
  end

  let(:job_without_pr) do
    Factories.job_record(user: user, repository: repository, issue_title: "Implement session management")
  end

  describe "#to_s in PR mode" do
    subject(:out) do
      described_class.new(
        epic: epic,
        jobs: [ job_with_pr, job_without_pr ],
        reconciliation_mode: "pr"
      ).to_s
    end

    it "names the Epic" do
      expect(out).to include("Unified Auth System")
    end

    it "lists each sibling Job by slug and title" do
      expect(out).to include(job_with_pr.slug)
      expect(out).to include("Implement OAuth login")
      expect(out).to include(job_without_pr.slug)
      expect(out).to include("Implement session management")
    end

    it "shows PR number for Jobs that have one" do
      expect(out).to include("PR #201")
    end

    it "shows '(not yet open)' for Jobs without a PR" do
      expect(out).to include("(not yet open)")
    end

    it "includes the fix-or-no-changes PR-mode instruction" do
      expect(out).to include("fix them in a single focused commit")
      expect(out).to include("Producing no changes closes this Job automatically")
    end

    it "does not include the feedback-mode submit_chat_feedback instruction" do
      expect(out).not_to include("submit_chat_feedback")
    end

    it "appends the git safety block after the mode instruction" do
      mode_pos   = out.index("fix them in a single focused commit")
      safety_pos = out.index(Prompts::GitSafety::TEXT)
      expect(mode_pos).to be < safety_pos
    end

    it "appends the submit-summary instructions last" do
      safety_pos  = out.index(Prompts::GitSafety::TEXT)
      summary_pos = out.index(Prompts::SubmitSummaryInstructions::TEXT)
      expect(safety_pos).to be < summary_pos
    end
  end

  describe "#to_s in feedback mode" do
    subject(:out) do
      described_class.new(
        epic: epic,
        jobs: [ job_with_pr, job_without_pr ],
        reconciliation_mode: "feedback"
      ).to_s
    end

    it "names the Epic" do
      expect(out).to include("Unified Auth System")
    end

    it "lists sibling Jobs" do
      expect(out).to include(job_with_pr.slug)
      expect(out).to include(job_without_pr.slug)
    end

    it "includes the submit_chat_feedback instruction" do
      expect(out).to include("submit_chat_feedback")
    end

    it "instructs the agent to make no further code changes" do
      expect(out).to include("make no further code changes")
    end

    it "does not include the fix-commit PR-mode instruction" do
      expect(out).not_to include("fix them in a single focused commit")
    end

    it "appends the git safety block" do
      expect(out).to include(Prompts::GitSafety::TEXT)
    end

    it "appends the submit-summary instructions" do
      expect(out).to include(Prompts::SubmitSummaryInstructions::TEXT)
    end
  end

  describe "default mode" do
    it "defaults to PR mode when reconciliation_mode is omitted" do
      out = described_class.new(epic: epic, jobs: [ job_with_pr ]).to_s
      expect(out).to include("fix them in a single focused commit")
      expect(out).not_to include("submit_chat_feedback")
    end
  end
end

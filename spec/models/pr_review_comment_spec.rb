require "rails_helper"

RSpec.describe PrReviewComment do
  let(:user) { Factories.user(github_handle: "alice") }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repo, issue_number: 10) }

  def build_comment(**attrs)
    PrReviewComment.new({
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: 1001,
      github_handle: "alice",
      attributed_to: "job_owner",
      actionable: true,
      body: "Please fix the typo",
      comment_created_at: 1.hour.ago
    }.merge(attrs))
  end

  it "creates with all required attributes" do
    comment = build_comment
    expect(comment.save).to be true
    expect(comment.persisted?).to be true
  end

  describe "validations" do
    it "requires pr_type" do
      comment = build_comment(pr_type: nil)
      expect(comment).not_to be_valid
      expect(comment.errors[:pr_type]).to be_present
    end

    it "rejects invalid pr_type" do
      comment = build_comment(pr_type: "unknown")
      expect(comment).not_to be_valid
    end

    it "requires comment_kind" do
      comment = build_comment(comment_kind: nil)
      expect(comment).not_to be_valid
    end

    it "rejects invalid comment_kind" do
      comment = build_comment(comment_kind: "inline")
      expect(comment).not_to be_valid
    end

    it "requires github_comment_id" do
      comment = build_comment(github_comment_id: nil)
      expect(comment).not_to be_valid
    end

    it "rejects invalid attributed_to" do
      comment = build_comment(attributed_to: "unknown_role")
      expect(comment).not_to be_valid
    end

    it "enforces uniqueness per job/pr_type/comment_kind/github_comment_id" do
      build_comment.save!
      duplicate = build_comment
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:github_comment_id]).to be_present
    end

    it "allows same github_comment_id for different pr_types" do
      build_comment(pr_type: "direct").save!
      other = build_comment(pr_type: "fork_review")
      expect(other).to be_valid
    end

    it "allows same github_comment_id for different comment_kinds" do
      build_comment(comment_kind: "issue").save!
      other = build_comment(comment_kind: "review")
      expect(other).to be_valid
    end
  end

  describe "#mark_actioned!" do
    it "records actioned_at and actioned_by" do
      comment = build_comment.tap(&:save!)
      comment.mark_actioned!(by: "auto_poll")
      expect(comment.actioned_at).to be_present
      expect(comment.actioned_by).to eq("auto_poll")
    end

    it "considers actioned comment as actioned?" do
      comment = build_comment.tap(&:save!)
      expect(comment.actioned?).to be false
      comment.mark_actioned!(by: "auto_poll")
      expect(comment.actioned?).to be true
    end
  end

  describe "attribution helpers" do
    it "reports job_owner? correctly" do
      expect(build_comment(attributed_to: "job_owner").job_owner?).to be true
      expect(build_comment(attributed_to: "member").job_owner?).to be false
    end

    it "reports member? correctly" do
      expect(build_comment(attributed_to: "member").member?).to be true
      expect(build_comment(attributed_to: "external").member?).to be false
    end

    it "reports external? correctly" do
      expect(build_comment(attributed_to: "external").external?).to be true
      expect(build_comment(attributed_to: "job_owner").external?).to be false
    end
  end

  describe "scopes" do
    before do
      build_comment(actionable: true, attributed_to: "job_owner", actioned_at: nil).save!
      build_comment(github_comment_id: 1002, actionable: false, attributed_to: "external", actioned_at: 1.hour.ago, actioned_by: "auto_poll").save!
    end

    it "actionable_comments returns only actionable" do
      expect(PrReviewComment.actionable_comments.count).to eq(1)
    end

    it "unactioned returns comments without actioned_at" do
      expect(PrReviewComment.unactioned.count).to eq(1)
    end

    it "for_pr_type filters by type" do
      build_comment(github_comment_id: 1003, pr_type: "fork_review").save!
      expect(PrReviewComment.for_pr_type("fork_review").count).to eq(1)
    end
  end
end

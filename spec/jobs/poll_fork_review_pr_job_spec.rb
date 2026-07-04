require "rails_helper"

RSpec.describe PollForkReviewPrJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:upstream) { Factories.repository(user: user, owner: "upstream-org", name: "widgets") }
  let(:fork_repo) { Factories.repository(user: user, owner: "acme", name: "widgets-fork", feedback_policy: "auto") }
  let(:job) do
    j = Factories.job(repository: fork_repo, issue_number: 42, target_repository: upstream)
    j.update!(branch_name: "syrus/issue-42-#{j.id}", fork_review_pr_number: 7)
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j
  end

  let(:fork_pr_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/pulls/7" }
  let(:reviews_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/pulls/7/reviews" }
  let(:issue_comments_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/issues/7/comments" }
  let(:review_comments_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/pulls/7/comments" }

  def stub_fork_pr(state: "open", merged: false)
    stub_request(:get, fork_pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: {
        number: 7,
        state: state,
        merged: merged,
        html_url: "https://github.com/acme/#{fork_repo.name}/pull/7"
      }.to_json
    )
  end

  def stub_reviews(reviews = [])
    stub_request(:get, reviews_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: reviews.to_json
    )
  end

  def stub_issue_comments(comments = [])
    stub_request(:get, issue_comments_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: comments.to_json
    )
  end

  def stub_review_comments(comments = [])
    stub_request(:get, review_comments_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: comments.to_json
    )
  end

  it "does nothing when the job has no fork_review_pr_number" do
    other_job = Factories.job(repository: fork_repo, issue_number: 99)
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(other_job.id)
  end

  it "does nothing when the job already has an upstream pr_number" do
    job.update!(pr_number: 50)
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(job.id)
  end

  it "does nothing when the job is closed" do
    job.close_with_reason!("manual")
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(job.id)
  end

  it "calls ForkReviewApprover with fork_pr_merged: true on accidental merge" do
    stub_fork_pr(state: "closed", merged: true)
    approver = instance_double(ForkReviewApprover)
    expect(ForkReviewApprover).to receive(:new).with(
      job,
      fork_client: instance_of(GithubClient)
    ).and_return(approver)
    expect(approver).to receive(:call).with(
      review_url: "https://github.com/acme/#{fork_repo.name}/pull/7",
      fork_pr_merged: true
    )

    described_class.perform_now(job.id)
  end

  it "does nothing when the fork PR is closed but not merged" do
    stub_fork_pr(state: "closed", merged: false)
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end

  it "calls ForkReviewApprover when a GitHub review approval is present" do
    stub_fork_pr
    stub_reviews([
      {
        state: "APPROVED",
        submitted_at: 1.hour.ago.iso8601,
        html_url: "https://github.com/acme/#{fork_repo.name}/pull/7#pullrequestreview-42"
      }
    ])
    approver = instance_double(ForkReviewApprover)
    expect(ForkReviewApprover).to receive(:new).with(
      job,
      fork_client: instance_of(GithubClient)
    ).and_return(approver)
    expect(approver).to receive(:call) do |**kwargs|
      # Simulate ForkReviewApprover setting pr_number (upstream PR created)
      job.update!(pr_number: 99)
    end

    described_class.perform_now(job.id)
  end

  it "does nothing when the open PR has no approvals" do
    stub_fork_pr
    stub_reviews([{ state: "COMMENTED", submitted_at: 1.hour.ago.iso8601 }])
    stub_issue_comments([])
    stub_review_comments([])
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end

  it "does nothing when the open PR has no reviews at all" do
    stub_fork_pr
    stub_reviews([])
    stub_issue_comments([])
    stub_review_comments([])
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end

  describe "fork review PR comment polling" do
    let(:t1) { 1.hour.ago }
    let(:t2) { 30.minutes.ago }

    before do
      stub_fork_pr
      stub_reviews([])
      allow(PrCommentClassifier).to receive(:call).and_return(
        PrCommentClassifier::Result.new(actionable: true, reason: "requests a change", error: nil)
      )
    end

    it "enqueues a pr_comment workflow for new actionable comments on the fork review PR" do
      stub_issue_comments([
        { id: 1, body: "Please fix the implementation before approval",
          user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      record = PrReviewComment.last
      expect(record.pr_type).to eq("fork_review")
      expect(record.attributed_to).to eq("external")
      expect(record.actionable).to be true
    end

    it "updates last_seen_fork_review_comment_at after processing" do
      stub_issue_comments([
        { id: 1, body: "Change this", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      described_class.perform_now(job.id)

      expect(job.reload.last_seen_fork_review_comment_at).to be_present
    end

    it "does not re-process already-seen comments" do
      job.update!(last_seen_fork_review_comment_at: t2)
      stub_issue_comments([
        { id: 1, body: "Old comment", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      # t1 (1 hour ago) < t2 (30 minutes ago), so the comment is before the watermark
      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }
    end

    it "does not enqueue workflow when comments are non-actionable" do
      allow(PrCommentClassifier).to receive(:call).and_return(
        PrCommentClassifier::Result.new(actionable: false, reason: "just praise", error: nil)
      )
      stub_issue_comments([
        { id: 1, body: "LGTM!", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }

      expect(PrReviewComment.count).to eq(1)
      expect(PrReviewComment.last.actionable).to be false
    end

    it "skips comment polling when an active pr_comment workflow is already pending" do
      Workflow.create!(job: job, trigger_kind: "pr_comment", state: "queued")
      stub_issue_comments([
        { id: 1, body: "More feedback", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }
    end

    it "is a no-op for comment polling when there are no comments" do
      stub_issue_comments([])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }
    end
  end
end

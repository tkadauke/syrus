require "rails_helper"

RSpec.describe PollPullRequestJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    j = Factories.job(repository: repository, issue_number: 42)
    j.update!(branch_name: "syrus/issue-42-#{j.id}", pr_number: 7)
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j
  end

  let(:slug) { "acme/widgets" }
  let(:pr_url) { "https://api.github.com/repos/acme/widgets/pulls/7" }
  let(:reviews_url) { "https://api.github.com/repos/acme/widgets/pulls/7/reviews" }
  let(:issue_comments_url) { "https://api.github.com/repos/acme/widgets/issues/7/comments" }
  let(:review_comments_url) { "https://api.github.com/repos/acme/widgets/pulls/7/comments" }
  let(:issue_url) { "https://api.github.com/repos/acme/widgets/issues/42" }

  before do
    # Octokit appends ?per_page=100 etc. to every call; match any query string.
    stub_request(:get, issue_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { number: 42, title: "Add greeting", body: "We need a greeting helper." }.to_json
    )
  end

  def stub_pr(state: "open", merged: false, labels: [], head_sha: "deadbeef0000000000000000000000000000beef")
    stub_request(:get, pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: {
        number: 7,
        state: state,
        merged: merged,
        labels: labels.map { |n| { name: n } },
        head: { sha: head_sha, ref: "syrus/issue-42-#{job.id}" }
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

  describe "close conditions" do
    it "closes the Job with reason=pr_merged when the PR is merged" do
      stub_pr(state: "closed", merged: true)
      expect { described_class.perform_now(job.id) }.to change { job.reload.state }.to("closed")
      expect(job.closure_reason).to eq("pr_merged")
    end

    it "closes the Job with reason=pr_closed when the PR is closed but not merged" do
      stub_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("pr_closed")
    end

    it "closes the Job with reason=syrus_stop when the PR carries the syrus-stop label" do
      stub_pr(labels: %w[syrus-stop])
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("syrus_stop")
    end

    it "closes the Job with reason=pr_approved on a new APPROVED review" do
      stub_pr
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601, user: { login: "reviewer" } }
      ])
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("pr_approved")
    end
  end

  describe "follow-up dispatch" do
    let(:t1) { Time.parse("2026-05-02 05:00:00 UTC") }
    let(:t2) { Time.parse("2026-05-02 05:05:00 UTC") }

    before do
      stub_pr
      stub_reviews([])
    end

    it "instantiates a PrFeedback workflow and stashes comments as artifacts" do
      stub_issue_comments([
        { id: 1, body: "Could you also handle empty strings?",
          user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([
        { id: 2, body: "Breaks on nil", path: "lib/greet.rb", line: 5,
          diff_hunk: "@@\n+ \"Hello, #{nil}!\"",
          user: { login: "reviewer" }, created_at: t2.iso8601, pull_request_review_id: nil }
      ])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      wf = job.workflows.where(trigger_kind: "pr_comment").last
      comments = wf.artifact("pr_comments")
      expect(comments.size).to eq(2)
      expect(comments.map { |c| c["body"] }).to contain_exactly(
        "Could you also handle empty strings?", "Breaks on nil"
      )
      expect(comments.find { |c| c["path"] == "lib/greet.rb" }["line"]).to eq(5)
      expect(job.reload.last_seen_comment_at.utc).to be_within(1.second).of(t2)
      expect(job.reload.last_feedback_addressed_at).to be_nil
    end

    it "does not schedule feedback that was already addressed successfully" do
      job.update!(last_feedback_addressed_at: t2)
      stub_issue_comments([
        { id: 1, body: "old feedback",
          user: { login: "reviewer" }, created_at: t1.iso8601 },
        { id: 2, body: "addressed feedback",
          user: { login: "reviewer" }, created_at: t2.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }
    end

    it "only schedules comments newer than the addressed feedback watermark" do
      t3 = Time.parse("2026-05-02 05:10:00 UTC")
      job.update!(last_feedback_addressed_at: t2)
      stub_issue_comments([
        { id: 1, body: "old feedback",
          user: { login: "reviewer" }, created_at: t1.iso8601 },
        { id: 2, body: "fresh feedback",
          user: { login: "reviewer" }, created_at: t3.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      wf = job.workflows.where(trigger_kind: "pr_comment").last
      expect(wf.artifact("pr_comments").map { |c| c["body"] }).to eq([ "fresh feedback" ])
    end

    it "uses an explicitly selected agent provider for PR feedback workflows" do
      stub_issue_comments([
        { id: 1, body: "Could you also handle empty strings?",
          user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id, manual: true, agent_provider: "codex")
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      wf = job.workflows.where(trigger_kind: "pr_comment").last
      expect(wf.agent_provider).to eq("codex")
      expect(wf.first_step.runs.last.agent_provider).to eq("codex")
    end

    it "DOES process operator-authored comments (Syrus runs under the operator's PAT today; the operator IS the reviewer)" do
      stub_issue_comments([
        { id: 1, body: "extract this into a helper",
          user: { login: "operator" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)
    end

    it "has no lifetime cap on pr_comment workflows — watermark is the safety" do
      # Many succeeded pr_comment workflows already; the watermark is
      # the only thing keeping the same comment from triggering more.
      10.times { Workflow.create!(job: job, trigger_kind: "pr_comment", state: "succeeded") }
      stub_issue_comments([
        { id: 1, body: "more feedback", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)
    end

    it "skips when an active pr_comment Workflow is already pending" do
      Workflow.create!(job: job, trigger_kind: "pr_comment", state: "queued")
      stub_issue_comments([
        { id: 1, body: "more feedback", user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "pr_comment").count }
    end

    it "is a no-op when there are no new comments" do
      stub_issue_comments([])
      stub_review_comments([])
      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.count }
    end
  end

  describe "guards" do
    it "no-ops when the Job is already closed" do
      stub_pr  # Need it because before block doesn't always run for guards
      job.close_with_reason!("manual")
      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.runs.count }
      # PR fetch shouldn't even happen
      expect(WebMock).not_to have_requested(:get, pr_url)
    end

    it "no-ops when the Job has no PR yet" do
      stub_pr
      bare = Factories.job(repository: repository, issue_number: 99)
      expect {
        described_class.perform_now(bare.id)
      }.not_to change { bare.runs.count }
    end
  end

  describe "graceful degradation on GitHub API permission errors" do
    before do
      stub_pr
      stub_reviews
    end

    it "clears gh_api_blocked when the next poll's pull_request fetch succeeds" do
      user.mark_gh_api_blocked!("stale earlier failure")
      stub_issue_comments
      stub_review_comments

      expect { described_class.perform_now(job.id) }
        .to change { user.reload.gh_api_blocked_at }.to(nil)
    end

    it "raises on a 403 from the pull_request fetch itself (whole poll is dead, banner explains)" do
      stub_request(:get, pr_url).with(query: hash_including({})).to_return(
        status: 403,
        headers: { "Content-Type" => "application/json" },
        body: { message: "Resource not accessible by personal access token", documentation_url: "https://docs.github.com" }.to_json
      )

      expect { described_class.perform_now(job.id) }
        .to raise_error(Octokit::Forbidden)
      expect(user.reload).to be_gh_api_blocked
    end
  end
end

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

  def stub_check_runs(sha, runs)
    url = "https://api.github.com/repos/acme/widgets/commits/#{sha}/check-runs"
    stub_request(:get, url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { total_count: runs.size, check_runs: runs }.to_json
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
      # CI branch fires too on every poll; default to "no checks" so
      # only the pr_comment branch can do anything in these tests.
      stub_check_runs("deadbeef0000000000000000000000000000beef", [])
    end

    it "instantiates a PrFeedback workflow, stashes comments as artifacts, advances the watermark" do
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

  describe "ci_failure dispatch" do
    let(:sha) { "abc1234567890000000000000000000000000000" }

    before do
      stub_pr(head_sha: sha)
      stub_reviews([])
      stub_issue_comments([])
      stub_review_comments([])
    end

    it "instantiates a CiFailure workflow with failed_checks + head_sha as artifacts" do
      rspec_log = Rails.root.join("spec/fixtures/ci_logs/rspec_failure.log").read
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "https://github.com/acme/widgets/runs/100",
          output: { summary: "RSpec: 2 examples, 1 failure (greet_spec.rb:14)", text: rspec_log } },
        { name: "lint", status: "completed", conclusion: "success",
          html_url: "https://github.com/acme/widgets/runs/101", output: { summary: "0 issues" } }
      ])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)

      wf = job.workflows.where(trigger_kind: "ci_failure").last
      failed = wf.artifact("failed_checks")
      expect(failed.size).to eq(1)
      # serialize_comment turns symbol-keyed hashes into string-keyed
      # ones; failed_checks comes through as the GithubClient-shaped
      # hash with symbol keys (we don't translate them — the Steps::
      # AnalyzeAndFix handler reads them as-is). Tolerate both.
      first = failed.first.to_h.transform_keys(&:to_s)
      context = first["error_context"].to_h.transform_keys(&:to_s)
      expect(first["name"]).to eq("test")
      expect(first["conclusion"]).to eq("failure")
      expect(first).not_to have_key("log")
      expect(context["parser"]).to eq("rspec")
      expect(context["error_summary"]).to eq("12 examples, 1 failure")
      expect(context["failing_tests"]).to include("GreetingHelper#greet returns the user's name")
      expect(context["error_block"]).not_to include("................................................................")
      expect(context["full_log_url"]).to eq("https://github.com/acme/widgets/runs/100")
      expect(wf.artifact("head_sha")).to eq(sha)
      expect(job.reload.last_ci_handled_sha).to eq(sha)
    end

    it "uses an explicitly selected agent provider for CI-failure workflows" do
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "https://github.com/acme/widgets/runs/100",
          output: { summary: "RSpec failed" } }
      ])

      expect {
        described_class.perform_now(job.id, manual: true, agent_provider: "codex")
      }.to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)

      wf = job.workflows.where(trigger_kind: "ci_failure").last
      expect(wf.agent_provider).to eq("codex")
      expect(wf.first_step.runs.last.agent_provider).to eq("codex")
    end

    it "is a no-op when all checks are passing" do
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "success",
          html_url: "u", output: { summary: "ok" } }
      ])
      expect { described_class.perform_now(job.id) }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
    end

    it "is a no-op when checks are still in_progress (don't act on partial state)" do
      stub_check_runs(sha, [
        { name: "test", status: "in_progress", conclusion: nil,
          html_url: "u", output: { summary: nil } }
      ])
      expect { described_class.perform_now(job.id) }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
    end

    it "doesn't re-react to the same head SHA twice" do
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])
      job.update!(last_ci_handled_sha: sha)

      expect { described_class.perform_now(job.id) }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
    end

    it "skips when an active ci_failure Workflow is already pending" do
      Workflow.create!(job: job, trigger_kind: "ci_failure", state: "queued")
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])
      expect { described_class.perform_now(job.id) }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
    end

    it "respects the cap (3 ci_failure workflows in the last 24h)" do
      3.times { Workflow.create!(job: job, trigger_kind: "ci_failure", state: "succeeded", created_at: 30.minutes.ago) }
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])
      expect { described_class.perform_now(job.id) }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
    end

    it "ignores ci_failure workflows older than the rolling window (cap recovers)" do
      # 3 stale workflows from way back — should not count toward the cap
      3.times { Workflow.create!(job: job, trigger_kind: "ci_failure", state: "succeeded", created_at: 2.days.ago) }
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])
      expect { described_class.perform_now(job.id) }
        .to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)
    end

    it "manual: true bypasses the ci_failure cap (operator override)" do
      3.times { Workflow.create!(job: job, trigger_kind: "ci_failure", state: "succeeded") }
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])
      expect { described_class.perform_now(job.id, manual: true) }
        .to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)
    end

    it "treats timed_out / action_required / cancelled as failures, ignores neutral / skipped" do
      stub_check_runs(sha, [
        { name: "build",  status: "completed", conclusion: "timed_out",       html_url: "u1", output: { summary: "timed out at 30m" } },
        { name: "deploy", status: "completed", conclusion: "action_required", html_url: "u2", output: { summary: "approve required" } },
        { name: "snyk",   status: "completed", conclusion: "neutral",         html_url: "u3", output: { summary: "no issues" } },
        { name: "skipme", status: "completed", conclusion: "skipped",         html_url: "u4", output: { summary: nil } }
      ])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "ci_failure").count }.by(1)

      wf = job.workflows.where(trigger_kind: "ci_failure").last
      names = wf.artifact("failed_checks").map { |c| (c["name"] || c[:name]) }
      expect(names).to include("build", "deploy")
      expect(names).not_to include("snyk")
      expect(names).not_to include("skipme")
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
    let(:check_runs_url) { "https://api.github.com/repos/acme/widgets/commits/deadbeef0000000000000000000000000000beef/check-runs" }

    before do
      stub_pr
      stub_reviews
    end

    it "records the user as gh_api_blocked when check-runs returns 403, and still processes new comments" do
      stub_request(:get, check_runs_url).with(query: hash_including({})).to_return(
        status: 403,
        headers: { "Content-Type" => "application/json" },
        body: { message: "Resource not accessible by personal access token", documentation_url: "https://docs.github.com" }.to_json
      )

      stub_issue_comments([
        { id: 1, body: "please fix the typo", user: { login: "reviewer" }, created_at: 1.minute.ago.iso8601 }
      ])
      stub_review_comments

      expect {
        described_class.perform_now(job.id)
      }.to change { user.reload.gh_api_blocked_at }.from(nil)
       .and change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      expect(user.reload.gh_api_blocked_reason).to include("check-runs")
      expect(user.reload.gh_api_blocked_reason).to include("Resource not accessible")
    end

    it "clears gh_api_blocked when the next poll's pull_request fetch succeeds" do
      user.mark_gh_api_blocked!("stale earlier failure")
      stub_request(:get, check_runs_url).with(query: hash_including({})).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { total_count: 0, check_runs: [] }.to_json
      )
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

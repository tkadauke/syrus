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
    # Allow branch deletion calls from the pr_merged close path (no-op 204 by default;
    # individual tests override if they need to verify the call or test error paths).
    stub_request(:delete, /api\.github\.com\/repos\/.*\/git\/refs\/heads\//).to_return(
      status: 204, body: ""
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

  def record_provider_transient_failure!(provider: "claude", issue_number:)
    failed_job = Factories.job(repository: repository, issue_number: issue_number, agent_provider: provider)
    Run.create!(
      job: failed_job,
      step: failed_job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: provider,
      agent_outcome: "provider_transient",
      finished_at: 1.minute.ago
    )
  end

  describe "close conditions" do
    it "closes the Job with reason=pr_merged when the PR is merged" do
      stub_pr(state: "closed", merged: true)
      expect { described_class.perform_now(job.id) }.to change { job.reload.state }.to("closed")
      expect(job.closure_reason).to eq("pr_merged")
    end

    it "closes the Job with reason=pr_closed when the PR is closed but not merged" do
      allow(ClosedPullRequestResolution).to receive(:reason).and_return("pr_closed")
      stub_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("pr_closed")
    end

    it "closes the Job with reason=no_changes when a closed PR has no unique patches left" do
      allow(ClosedPullRequestResolution).to receive(:reason).and_return("no_changes")
      stub_pr(state: "closed", merged: false)

      described_class.perform_now(job.id)

      expect(job.reload.closure_reason).to eq("no_changes")
    end

    it "closes the Job with reason=syrus_stop when the PR carries the syrus-stop label" do
      stub_pr(labels: %w[syrus-stop])
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("syrus_stop")
    end

    it "leaves the Job open on a new APPROVED review when auto-merge is enabled" do
      repository.update!(auto_merge_enabled: true)
      stub_pr
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601, html_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1", user: { login: "reviewer" } }
      ])
      stub_issue_comments([])
      stub_review_comments([])
      stub_check_runs("deadbeef0000000000000000000000000000beef", [])

      described_class.perform_now(job.id)

      expect(job.reload).to be_open
      expect(job.state).to eq("approved")
      expect(job.approved_at).to be_present
      expect(job.approved_via).to eq("github_review")
      expect(job.approval_evidence).to eq("github_review_url" => "https://github.com/acme/widgets/pull/7#pullrequestreview-1")
      expect(job.closure_reason).to be_nil
    end

    it "clears approval when fresh PR feedback is queued after an APPROVED review" do
      repository.update!(auto_merge_enabled: false)
      stub_pr
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601, html_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1", user: { login: "reviewer" } }
      ])
      stub_issue_comments([
        { id: 1, body: "please address this before manual merge",
          user: { login: "reviewer" }, created_at: 1.minute.ago.iso8601 }
      ])
      stub_review_comments([])
      stub_check_runs("deadbeef0000000000000000000000000000beef", [])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      expect(job.reload).to be_open
      expect(job.state).to eq("implemented")
      expect(job.approved_via).to be_nil
      expect(job.approved_at).to be_nil
      expect(job.closure_reason).to be_nil
    end

    it "closes with reason=pr_merged after a manually merged approved PR when auto-merge is disabled" do
      repository.update!(auto_merge_enabled: false)
      stub_pr(state: "closed", merged: true)

      expect { described_class.perform_now(job.id) }.to change { job.reload.state }.to("closed")
      expect(job.closure_reason).to eq("pr_merged")
    end

    it "keeps the Job open (transitions to approved) on a new APPROVED review when auto-merge is disabled" do
      # An APPROVED review moves the Job to `approved` state — which
      # is still `open?` per Job#open? (== !closed? && !merged?). The
      # earlier assertion `not_to change { job.reload.state }` was a
      # misread of "keeps the Job open" as "doesn't change state";
      # they're separate concerns.
      stub_pr
      stub_reviews([
        { id: 1, state: "APPROVED", submitted_at: Time.current.iso8601, html_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1", user: { login: "reviewer" } }
      ])
      stub_issue_comments([])
      stub_review_comments([])
      stub_check_runs("deadbeef0000000000000000000000000000beef", [])

      described_class.perform_now(job.id)

      expect(job.reload).to be_open
      expect(job.state).to eq("approved")
      expect(job.approved_via).to eq("github_review")
      expect(job.closure_reason).to be_nil
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

    it "attaches markdown images from PR feedback comments to the Job" do
      image_body = "\x89PNG\r\n\x1A\nreview-image".b
      stub_request(:get, "https://uploads.example.com/state.png").to_return(
        status: 200,
        headers: { "Content-Type" => "image/png", "Content-Length" => image_body.bytesize.to_s },
        body: image_body
      )
      stub_issue_comments([
        { id: 1, body: "Broken state: ![screenshot](https://uploads.example.com/state.png)",
          user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([
        { id: 2, body: "Same image inline: ![again](https://uploads.example.com/state.png)",
          path: "app/views/widgets/show.html.erb", line: 12,
          user: { login: "reviewer" }, created_at: t2.iso8601, pull_request_review_id: nil }
      ])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.job_attachments.count }.by(1)
        .and change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      attachment = job.job_attachments.last
      expect(attachment.source_url).to eq("https://uploads.example.com/state.png")
      expect(attachment.file).to be_attached
      expect(attachment.file.download).to eq(image_body)
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

    it "fires when at least one comment is newer than the addressed feedback watermark — and stashes the full thread + cutoff" do
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
      # Full thread is preserved so the agent sees the arc — prior
      # rounds + new feedback both rendered, with [NEW] tagging via
      # the cutoff timestamp.
      expect(wf.artifact("pr_comments").map { |c| c["body"] }).to eq([ "old feedback", "fresh feedback" ])
      expect(wf.artifact("feedback_cutoff")).to eq(t2.iso8601)
    end

    it "manual polls retry feedback that was seen but not successfully addressed" do
      job.update!(last_seen_comment_at: t1)
      stub_issue_comments([
        { id: 1, body: "old but still unaddressed feedback",
          user: { login: "reviewer" }, created_at: t1.iso8601 }
      ])
      stub_review_comments([])

      expect {
        described_class.perform_now(job.id, manual: true)
      }.to change { job.workflows.where(trigger_kind: "pr_comment").count }.by(1)

      wf = job.workflows.where(trigger_kind: "pr_comment").last
      expect(wf.artifact("pr_comments").map { |c| c["body"] }).to eq([ "old but still unaddressed feedback" ])
      expect(wf.artifact("feedback_cutoff")).to be_nil
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

    it "suppresses autonomous ci_failure workflows while the provider circuit is open" do
      5.times { |index| record_provider_transient_failure!(issue_number: index + 100) }
      stub_check_runs(sha, [
        { name: "test", status: "completed", conclusion: "failure",
          html_url: "u", output: { summary: "fail" } }
      ])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "ci_failure").count }
      expect(job.reload.last_ci_handled_sha).to be_nil
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

  describe "branch deletion on merge" do
    let(:branch_name) { job.branch_name }
    let(:delete_ref_url) { "https://api.github.com/repos/acme/widgets/git/refs/heads/#{branch_name}" }

    it "deletes the branch and stamps branch_deleted_at when the PR is merged" do
      stub_pr(state: "closed", merged: true)
      delete_stub = stub_request(:delete, delete_ref_url).to_return(status: 204, body: "")

      described_class.perform_now(job.id)

      expect(delete_stub).to have_been_requested
      expect(job.reload.branch_deleted_at).to be_present
    end

    it "does not delete the branch for other close reasons" do
      allow(ClosedPullRequestResolution).to receive(:reason).and_return("pr_closed")
      stub_pr(state: "closed", merged: false)
      delete_stub = stub_request(:delete, delete_ref_url).to_return(status: 204, body: "")

      described_class.perform_now(job.id)

      expect(delete_stub).not_to have_been_requested
      expect(job.reload.branch_deleted_at).to be_nil
    end

    it "skips branch deletion when branch_name is absent" do
      job.update!(branch_name: nil)
      stub_pr(state: "closed", merged: true)
      delete_stub = stub_request(:delete, /git\/refs\/heads/).to_return(status: 204, body: "")

      described_class.perform_now(job.id)

      expect(delete_stub).not_to have_been_requested
    end
  end
end

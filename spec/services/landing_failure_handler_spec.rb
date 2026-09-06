require "rails_helper"

RSpec.describe LandingFailureHandler do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def landing_job
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 7,
      state: "implemented"
    ).tap do |job|
      job.approve!(via: "github_review")
      job.start_landing!
      job.save!
    end
  end

  def auto_merge_run(job)
    workflow = Workflows::AutoMerge.instantiate(job: job)
    step = workflow.steps.last
    step.runs.create!(job: job, trigger_kind: "auto_merge", agent_provider: workflow.agent_provider)
  end

  # A failure that says nothing about whether the work is landable used to be
  # treated exactly like a grader rejection: revert to :implemented and clear
  # the approval. So a five-second GitHub outage, or an MCP sidecar that did
  # not come up, cost an operator a round of re-approving every member of a
  # merge train.
  describe "transient failures" do
    [
      "POST https://api.github.com/repos/acme/widgets/pulls: 502 - No server is currently available to service your request.",
      "agent reported mcp_sidecar_failed",
      "active WorkUnit #12 already owns lock landing:repository:3",
      "Octokit::BadGateway: 502 Bad Gateway"
    ].each do |reason|
      it "keeps the approval and defers for: #{reason.truncate(48)}" do
        job = landing_job
        approved_at = job.approved_at

        described_class.call(job: job, reason: reason)

        expect(job.reload).to be_approved
        expect(job.approved_at).to eq(approved_at)
      end
    end

    # Deferral, not a pause: pausing landing instance-wide is the right answer
    # to a full disk and far too heavy for a bad minute at GitHub.
    it "does not pause landing for the user" do
      job = landing_job

      described_class.call(job: job, reason: "Octokit::ServiceUnavailable: 503")

      expect(job.user.reload).not_to be_landing_paused
    end

    it "still fails a genuine grader rejection" do
      job = landing_job

      described_class.call(job: job, reason: "auto_merge: required grader rspec failed (exit 1)")

      expect(job.reload).to be_implemented
      expect(job.approved_at).to be_nil
    end
  end

  it "fails ordinary landing failures back to implemented and clears approval" do
    job = landing_job
    approved_at = job.approved_at

    described_class.call(job: job, reason: "auto_merge: required grader failed")

    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
    expect(job.approved_at).not_to eq(approved_at)
    expect(job.landing_failure_reason).to eq("auto_merge: required grader failed")
    expect(user.reload.landing_paused).to eq(false)
  end

  it "pauses landing and preserves approval for infrastructure blockers" do
    job = landing_job
    run = auto_merge_run(job)
    approved_at = job.approved_at

    described_class.call(
      job: job,
      run: run,
      reason: "Errno::ENOSPC: No space left on device @ rb_sysopen - /home/rails/.syrus/foo"
    )

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(approved_at)
    expect(job.landing_failure_reason).to include("No space left on device")
    expect(user.reload.landing_paused).to eq(true)
    expect(run.job_logs.pluck(:chunk)).to include(include("landing_queue: paused landing"))
  end

  it "preserves approval for rebase cap blockers without globally pausing landing" do
    job = landing_job
    run = auto_merge_run(job)
    approved_at = job.approved_at

    described_class.call(
      job: job,
      run: run,
      reason: "Steps::Base::StepFailed: auto_merge: PR mergeable_state is \"dirty\" and rebase cap reached"
    )

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(approved_at)
    expect(job.landing_failure_reason).to include("rebase cap reached")
    expect(user.reload.landing_paused).to eq(false)
    expect(run.job_logs.pluck(:chunk)).to include(include("landing_queue: deferred landing because the rebase cap was reached"))
  end

  it "preserves approval for stale merge-train builds so the train can rebuild" do
    job = landing_job
    run = auto_merge_run(job)
    approved_at = job.approved_at

    described_class.call(
      job: job,
      run: run,
      reason: "merge_train: missing built base SHA; rebuild required"
    )

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(approved_at)
    expect(job.landing_failure_reason).to include("missing built base SHA")
    expect(user.reload.landing_paused).to eq(false)
    expect(run.job_logs.pluck(:chunk)).to include(include("merge-train validation is stale or incomplete"))
  end

  it "requires re-approval for genuine merge-train integration conflicts" do
    job = landing_job

    described_class.call(
      job: job,
      reason: "merge_train: integration PR has merge conflicts for PR #123: Pull Request has merge conflicts; operator intervention required"
    )

    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
    expect(job.landing_failure_reason).to include("integration PR has merge conflicts")
    expect(user.reload.landing_paused).to eq(false)
  end
end

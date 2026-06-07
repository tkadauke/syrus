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

  it "pauses landing and preserves approval for missing permission blockers" do
    job = landing_job
    run = auto_merge_run(job)
    approved_at = job.approved_at

    described_class.call(
      job: job,
      run: run,
      reason: "Octokit::Forbidden: Resource not accessible by integration"
    )

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(approved_at)
    expect(job.landing_failure_reason).to include("Resource not accessible")
    expect(user.reload.landing_paused).to eq(true)
    expect(run.job_logs.pluck(:chunk)).to include(include("operator-required blocker"))
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
    expect(run.job_logs.pluck(:chunk)).to include(include("operator-required blocker"))
  end
end

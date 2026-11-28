require "rails_helper"

RSpec.describe Invariants::LandingProgress do
  let(:later) { Time.current + 3.hours }

  def approved_job(**attrs)
    job = Factories.job_with_run(state: "approved", workflow_attrs: { state: "succeeded", finished_at: Time.current },
                                 step_attrs: { state: "succeeded" }, run_attrs: { state: "succeeded" }, **attrs)
    job.update_columns(approved_at: Time.current)
    job
  end

  it "reports an approved Job that nothing moves or holds past the threshold" do
    job = approved_job

    violations = described_class.call(now: later)

    expect(violations.size).to eq(1)
    violation = violations.first
    expect(violation.fingerprint).to eq("landing_progress:Job:#{job.id}")
    expect(violation.severity).to eq("critical")
    expect(violation.details).to include("job" => include("id" => job.id, "state" => "approved"), "active_runs" => 0, "active_work_units" => 0)
    expect(violation.details.dig("latest_workflow", "state")).to eq("succeeded")
    expect(violation.message).to include(job.slug, "approved")
  end

  it "does not report the Job before the threshold elapses" do
    approved_job

    expect(described_class.call(now: Time.current + 1.hour)).to be_empty
    expect(described_class.call(now: later, threshold: 4.hours)).to be_empty
  end

  it "does not report a Job with an active Run" do
    job = approved_job
    job.runs.first.update_columns(state: "running")

    expect(described_class.call(now: later)).to be_empty
  end

  it "does not report a Job held by an active WorkUnit" do
    job = approved_job
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "auto_merge", state: "queued")
    attach_work_unit(workflow, state: "blocked", blocked_reason: "admission_control")
    Workflow.where(id: workflow.id).update_all(updated_at: 4.hours.ago)
    WorkUnit.where(workflow_id: workflow.id).update_all(updated_at: 4.hours.ago)

    expect(described_class.call(now: later)).to be_empty
  end

  it "does not report a Job with a named landing queue blocker" do
    job = approved_job
    job.update_columns(landing_queue_blocked_reason: { "key" => "pr_checks_failing" })

    expect(described_class.call(now: later)).to be_empty
  end

  # Regression: a Job whose PR needs a rebase while every rebase slot is held
  # by runnable work had no landing-queue reason, so this check reported it as
  # stranded although it was only waiting its turn.
  it "treats a wait for a rebase slot as a named landing reason" do
    job = approved_job
    job.repository.update!(auto_merge_enabled: true)
    job.update_columns(pr_number: 77, github_mergeable_state: "behind", mergeability_checked_at: Time.current)
    PollRebaseJob::CONCURRENT_REBASES_PER_REPO.times do |index|
      other = Factories.job_record(user: job.user, repository: job.repository, state: "implemented",
                                   pr_number: 300 + index, branch_name: "syrus/slot-holder-#{index}")
      RebaseWorkflowSelector.instantiate(job: other)
    end
    LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id))

    expect(job.reload.landing_queue_blocked_reason).to include("key" => "waiting_rebase_slot")
    expect(described_class.call(now: later)).to be_empty
  end

  # Regression: the landing queue holds a Job whose PR has requested changes
  # without ever listing it (queue_candidates drops it, so its snapshot stays
  # empty), and this check reported an approved Job held for months on a review
  # as having "no named landing blocker".
  it "treats a requested-changes hold as the named landing blocker the queue computes" do
    job = approved_job
    job.update_columns(needs_attention: true, needs_attention_reason: Job::REQUESTED_CHANGES_ATTENTION_REASON)
    LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id))

    expect(job.reload.landing_queue_blocked_reason).to be_nil
    expect(described_class.call(now: later)).to be_empty

    job.update_columns(needs_attention_reason: Job::UNAPPLIED_FEEDBACK_ATTENTION_REASON)
    expect(described_class.call(now: later)).to be_empty

    job.update_columns(needs_attention: false, needs_attention_reason: nil)
    expect(described_class.call(now: later).size).to eq(1)
  end

  it "does not report a Job waiting behind other Jobs in the landing queue" do
    job = approved_job
    job.update_columns(landing_queue_blocker_job_ids: [ job.id + 1000 ])

    expect(described_class.call(now: later)).to be_empty
  end

  it "evaluates only in-scope Jobs" do
    job = approved_job

    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ job.id + 1 ]))).to be_empty
    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ job.id ])).size).to eq(1)
  end
end

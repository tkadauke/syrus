require "rails_helper"

RSpec.describe ReconcileJobStatesJob do
  include ActiveJob::TestHelper

  let(:job) do
    j = Factories.job
    j.runs.destroy_all
    j.workflows.destroy_all
    j
  end

  # Factories.job leaves an active WorkUnit behind, and every drift pair is
  # gated on "no active runtime work" -- without this the Job looks mid-flight
  # and no plan is ever produced.
  def finish_work_units!
    unit_ids = WorkUnitMember.where(job_id: job.id).select(:work_unit_id)
    WorkUnit.where(id: unit_ids).update_all(state: "succeeded", finished_at: Time.current)
  end

  def build_workflow(state:, trigger_kind: "pr_comment", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
    Workflow.create!(
      job: job, trigger_kind: trigger_kind, state: state,
      started_at: started_at,
      finished_at: %w[ succeeded failed cancelled ].include?(state) ? finished_at : nil
    )
  end

  # Every other queued/* pair was in the drift table; this one was not, and it
  # is the pair that costs an operator the most. A Workflow whose first Run
  # fails before the Workflow starts leaves the Job at :queued -- `mark_failed`
  # only transitions from :running -- so the Job reads healthy in every
  # surface, "Just failed" included, while nothing works on it. JOB-4253 sat
  # like that for fifteen hours with three Jobs blocked behind it.
  describe "a workflow that failed while the Job never left :queued" do
    it "plans the Job to failed" do
      build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      plan = ReconcileJobStatesJob::Plan.for(job.reload)

      expect(plan).to be_present
      expect(plan.target_state).to eq("failed")
      expect(plan.reason).to match(/stuck at :queued/)
    end

    it "makes the Job discoverable in the Just failed folder" do
      build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      finish_work_units!

      ReconcileJobStatesJob::Plan.for(job.reload).apply!

      expect(job.reload).to be_failed
    end

    # A Job with live work is mid-flight, not stranded -- the same guard every
    # other drift pair uses.
    it "leaves a Job alone while it still has active runtime work" do
      workflow = build_workflow(state: "failed", started_at: nil)
      job.update!(state: "queued")
      step = Step.create!(workflow: workflow, kind: "prepare", state: "running", position: 0)
      Run.create!(job: job, step: step, trigger_kind: "initial", state: "running")

      expect(ReconcileJobStatesJob::Plan.for(job.reload)).to be_nil
    end
  end

  it "always delegates to the unified reconciler without mutating Jobs directly" do
    build_workflow(state: "succeeded")
    job.update!(state: "failed")

    expect {
      described_class.perform_now
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "ReconcileJobStatesJob",
      job_id: nil,
      workflow_id: nil,
      run_id: nil
    )

    expect(job.reload.state).to eq("failed")
  end
end

require "rails_helper"

RSpec.describe AutoRetryScheduler do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  around do |example|
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def fail_workflow!(agent_outcome: "worker_died")
    run.update_columns(state: "failed", agent_outcome: agent_outcome, agent_provider: "claude", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")
  end

  it "always delegates to the unified reconciler without scheduling auto-retries directly" do
    fail_workflow!

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.to change { workflow.runs.order(:created_at).last.job_logs.where(kind: "system").count }.by(1)
      .and have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "AutoRetryScheduler",
        job_id: job.id,
        workflow_id: workflow.id,
        run_id: nil
      )

    expect(AutoRetryAttempt.count).to eq(0)
    expect(workflow.runs.order(:created_at).last.job_logs.where(kind: "system").last.chunk)
      .to eq("auto-retry skipped: unified work-engine reconciler handles retry scheduling")
  end

  it "is a no-op when the workflow is not failed" do
    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to have_enqueued_job(WorkEngine::ReconcileJob)

    expect(AutoRetryAttempt.count).to eq(0)
  end
end

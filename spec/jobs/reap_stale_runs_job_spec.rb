require "rails_helper"

RSpec.describe ReapStaleRunsJob do
  include ActiveJob::TestHelper

  let(:job) { Factories.job }

  describe "#perform" do
    def stale_workflow_run
      workflow = job.latest_workflow
      step = workflow.first_step
      run = step.runs.first
      age = Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes
      workflow.update_columns(state: "running", started_at: age.ago)
      step.update_columns(state: "running", started_at: age.ago)
      run.update_columns(
        state: "running",
        started_at: age.ago,
        last_heartbeat_at: age.ago
      )
      run
    end

    it "always delegates to the unified reconciler" do
      expect {
        described_class.perform_now
      }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "ReapStaleRunsJob",
        job_id: nil,
        workflow_id: nil,
        run_id: nil
      )
    end

    it "releases stale running Runs through the unified reconciler" do
      run = stale_workflow_run

      expect {
        described_class.perform_now
      }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "ReapStaleRunsJob",
        job_id: nil,
        workflow_id: nil,
        run_id: nil
      )

      perform_enqueued_jobs(only: WorkEngine::ReconcileJob)
      expect(run.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
    end
  end
end

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

    it "frees worker-slot admission after the reconciler marks a stale Run worker_died" do
      allow(SyrusVersion).to receive(:hostname).and_return("worker-a")
      allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-a")
      stale = stale_workflow_run
      stale.workflow.update_columns(worker_hostname: "worker-a", worker_storage_key: "storage-a")
      WorkflowStepWorkerSlot.acquire!(run: stale, hostname: "worker-a", storage_key: "storage-a")

      queued_job = Factories.job_record(user: job.user, repository: job.repository, state: "queued", issue_number: 5001)
      queued_workflow = Workflows::Initial.instantiate(job: queued_job, agent_provider: "codex")
      queued_workflow.update_columns(worker_hostname: "worker-a", worker_storage_key: "storage-a")
      queued_run = queued_workflow.first_step.runs.create!(
        job: queued_job,
        trigger_kind: queued_workflow.trigger_kind,
        agent_provider: queued_workflow.agent_provider
      )

      before_reap = RunHostAdmission.call(run: queued_run)
      expect(before_reap).to be_defer
      expect(before_reap.reason).to eq("worker_step_slot_busy")

      described_class.perform_now
      perform_enqueued_jobs(only: WorkEngine::ReconcileJob)

      after_reap = RunHostAdmission.call(run: queued_run.reload)
      expect(stale.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
      expect(after_reap).to be_admit
      expect(after_reap.reason).to eq("worker_step_slot_available")
    end
  end
end

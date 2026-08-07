require "rails_helper"

RSpec.describe ProviderAdmissionWakeup do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def fail_workflow!
    run.update_columns(state: "failed", agent_outcome: "worker_died", agent_provider: "claude", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")
  end

  def pending_attempt(scheduled_at: 10.minutes.from_now)
    fail_workflow!
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: scheduled_at
    )
  end

  def closed_circuit
    ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: false,
      reason: "provider healthy",
      retry_after: nil,
      failure_count: 0,
      job_count: 0,
      signature: nil
    )
  end

  def open_circuit
    ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider degraded",
      retry_after: 30.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: nil
    )
  end

  describe ".call" do
    it "cancels future-scheduled auto-retry attempts and requests a reconcile for each affected job" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
        source: "ProviderAdmissionWakeup",
        job_id: job.id,
        workflow_id: nil,
        run_id: nil
      )

      expect(attempt.reload.skipped_reason).to eq("provider circuit reopened; reconciler will retry immediately")
      expect(attempt.performed_at).to be_nil
    end

    it "returns a result with the woken attempt ids" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      result = described_class.call(provider: "claude")

      expect(result.auto_retry_attempt_ids).to eq([ attempt.id ])
      expect(result.provider).to eq("claude")
    end

    it "is a no-op when the provider circuit is still open" do
      pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(open_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)
    end

    it "ignores already-performed or skipped attempts" do
      attempt = pending_attempt
      attempt.update!(performed_at: Time.current)
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)
    end

    it "ignores past-due attempts (scheduled in the past)" do
      attempt = pending_attempt(scheduled_at: 5.minutes.ago)
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        described_class.call(provider: "claude")
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)

      expect(attempt.reload.skipped_reason).to be_nil
    end
  end

  describe ".preview" do
    it "returns the attempt ids without side effects" do
      attempt = pending_attempt
      allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)

      expect {
        result = described_class.preview(provider: "claude")
        expect(result.auto_retry_attempt_ids).to eq([ attempt.id ])
      }.not_to have_enqueued_job(WorkEngine::ReconcileJob)

      expect(attempt.reload.skipped_reason).to be_nil
    end
  end
end

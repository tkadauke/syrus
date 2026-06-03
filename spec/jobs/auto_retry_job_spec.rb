require "rails_helper"

RSpec.describe AutoRetryJob do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def failed_attempt!(retry_kind:)
    run.update!(state: "failed", agent_outcome: "worker_died", agent_provider: "claude", finished_at: Time.current)
    step.update!(state: "failed", finished_at: Time.current)
    workflow.update!(state: "failed", finished_at: Time.current, cleaned_up_at: (Time.current if retry_kind == "retry_workflow"))
    job.update!(state: "failed")
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: retry_kind,
      attempt_number: 1,
      scheduled_at: Time.current
    )
  end

  it "uses the failed-step retry path when the workspace is still available" do
    attempt = failed_attempt!(retry_kind: "failed_step")

    expect {
      described_class.perform_now(attempt.id)
    }.to change { step.runs.count }.by(1)

    expect(attempt.reload.performed_at).to be_present
    expect(workflow.reload).to be_running
    expect(step.reload).to be_queued
  end

  it "uses RetryWorkflowEnqueuer for retry-workflow attempts" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    result = RetryWorkflowEnqueuer::Result.new(workflow: instance_double(Workflow), error: nil)
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(result)

    described_class.perform_now(attempt.id)

    expect(RetryWorkflowEnqueuer).to have_received(:call).with(
      job: job,
      agent_provider: "claude",
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      provider_validation: :none
    )
    expect(attempt.reload.performed_at).to be_present
  end

  it "records skipped attempts when the retry primitive rejects the run" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
      RetryWorkflowEnqueuer::Result.new(workflow: nil, error: "A Run is already in progress")
    )

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("A Run is already in progress")
    expect(attempt.performed_at).to be_nil
  end
end

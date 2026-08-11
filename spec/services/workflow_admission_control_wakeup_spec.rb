require "rails_helper"

RSpec.describe WorkflowAdmissionControlWakeup do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "enqueues deferred admission workflows and landing queue reprocessing" do
    job = Factories.job_record(user: user, repository: repository, state: "queued")
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "codex")
    workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => { "action" => "delay_until" }
      }
    )

    expect {
      result = described_class.call
      expect(result.workflow_ids).to eq([ workflow.id ])
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
      .and have_enqueued_job(LandingQueueProcessorJob)
  end

  it "does not wake manual or provider pauses as admission-control sleepers" do
    manual_job = Factories.job_record(user: user, repository: repository, state: "queued")
    manual_workflow = Workflows::Initial.instantiate(job: manual_job, agent_provider: "codex")
    manual_workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::MANUAL_PAUSE_REASON,
        "pause_reason" => StepDispatcher::MANUAL_PAUSE_REASON
      }
    )
    provider_job = Factories.job_record(user: user, repository: repository, state: "queued")
    provider_workflow = Workflows::Initial.instantiate(job: provider_job, agent_provider: "codex")
    provider_workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
        "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
      }
    )

    expect {
      result = described_class.call
      expect(result.workflow_ids).to eq([])
    }.not_to have_enqueued_job(WorkflowPhaseAdmissionJob)
  end

  it "reconsiders future auto-retry sleepers through the reconciler" do
    retry_job = Factories.job(agent_provider: "claude")
    retry_workflow = retry_job.latest_workflow
    run = retry_workflow.runs.first
    attempt = AutoRetryAttempt.create!(
      job: retry_job,
      workflow: retry_workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: 20.minutes.from_now
    )

    expect {
      result = described_class.call
      expect(result.auto_retry_attempt_ids).to eq([ attempt.id ])
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "WorkflowAdmissionControlWakeup",
      job_id: retry_job.id,
      workflow_id: nil,
      run_id: nil
    )

    expect(attempt.reload.skipped_reason).to eq("workflow admission control changed; reconciler will retry immediately")
    expect(attempt.performed_at).to be_nil
  end
end

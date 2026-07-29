require "rails_helper"

RSpec.describe AutoRetryJob do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def failed_attempt!(retry_kind:)
    run.update_columns(state: "failed", agent_outcome: "worker_died", agent_provider: "claude", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: (Time.current if retry_kind == "retry_workflow"))
    job.update_columns(state: "failed")
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

  def failed_agentic_attempt!(retry_kind:)
    agent_step = workflow.steps.find_by!(kind: "implement")
    agent_run = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "failed",
      agent_outcome: "worker_died",
      finished_at: Time.current
    )
    ClaudeSession.create!(
      resumable: agent_run,
      provider: "claude",
      session_id: "claude-thread",
      transcript_jsonl: "{}\n"
    )
    agent_step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")
    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: agent_run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: retry_kind,
      attempt_number: 1,
      scheduled_at: Time.current
    )
    [ attempt, agent_step, agent_run ]
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
    result = RetryWorkflowEnqueuer::Result.new(workflow: instance_double(Workflow), error: nil, circuit: nil)
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(result)

    described_class.perform_now(attempt.id)

    expect(RetryWorkflowEnqueuer).to have_received(:call).with(
      job: job,
      agent_provider: "claude",
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      provider_validation: :none,
      automatic: true
    )
    expect(attempt.reload.performed_at).to be_present
  end

  it "resumes the failed agentic step in the original workflow" do
    attempt, agent_step, _agent_run = failed_agentic_attempt!(retry_kind: "resume_failed_step")

    expect {
      described_class.perform_now(attempt.id)
    }.to change { agent_step.runs.count }.by(1)

    expect(attempt.reload.performed_at).to be_present
    expect(workflow.reload).to be_running
    expect(agent_step.reload).to be_queued

    resumed_run = agent_step.runs.order(:created_at).last
    expect(resumed_run.parent_session_id).to eq("claude-thread")
    expect(resumed_run.prompt).to eq(Prompts::Resume.new.to_s)
    expect(resumed_run.agent_provider).to eq("claude")
    expect(resumed_run.workflow_id).to eq(workflow.id)
  end

  it "falls back to a retry workflow when a failed-step retry lost its workspace" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    workflow.update!(cleaned_up_at: Time.current)
    result = RetryWorkflowEnqueuer::Result.new(workflow: instance_double(Workflow), error: nil, circuit: nil)
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(result)

    described_class.perform_now(attempt.id)

    expect(RetryWorkflowEnqueuer).to have_received(:call).with(
      job: job,
      agent_provider: "claude",
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      provider_validation: :none,
      automatic: true
    )
    expect(attempt.reload.performed_at).to be_present
  end

  it "records skipped attempts when the retry primitive rejects the run" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
      RetryWorkflowEnqueuer::Result.new(workflow: nil, error: "A Run is already in progress", circuit: nil)
    )

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("A Run is already in progress")
    expect(attempt.performed_at).to be_nil
  end

  it "records a skipped reason and starts no workflow when the provider circuit is open" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    open_circuit = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider transient failures",
      retry_after: 10.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: nil
    )
    allow(ProviderCircuitBreaker).to receive(:call).and_return(open_circuit)

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to include("appears degraded")
    expect(attempt.performed_at).to be_nil
    expect(job.workflows.count).to eq(1)
  end
end

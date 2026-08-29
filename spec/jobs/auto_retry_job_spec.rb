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
    ProviderSession.create!(
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

  it "disables provider resume for agent-resume-unavailable failed-step attempts" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    attempt.update!(failure_classification: "agent_resume_unavailable")

    described_class.perform_now(attempt.id)

    retry_run = step.runs.order(:created_at).last
    expect(retry_run.parent_session_id).to eq(Steps::Base::DISABLE_AGENT_RESUME)
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

  it "records skipped failed-step attempts when the retry primitive rejects the run" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(
      RetryFailedStepEnqueuer::Result.new(run: nil, workflow: workflow, step: step, error: "No failed step to retry.")
    )

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("No failed step to retry.")
    expect(attempt.performed_at).to be_nil
  end

  it "retries failed steps with the provider recorded on the retry attempt" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    attempt.update!(agent_provider: "codex")
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(
      RetryFailedStepEnqueuer::Result.new(run: instance_double(Run), workflow: workflow, step: step, error: nil)
    )

    described_class.perform_now(attempt.id)

    expect(RetryFailedStepEnqueuer).to have_received(:call).with(
      workflow: workflow,
      agent_provider: "codex",
      disable_session_resume: false
    )
    expect(attempt.reload.performed_at).to be_present
  end

  it "reschedules failed-step attempts when another active WorkUnit owns the lock" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(
      RetryFailedStepEnqueuer::Result.new(
        run: nil,
        workflow: workflow,
        step: step,
        error: "#{RetryFailedStepEnqueuer::ACTIVE_WORK_LOCK_ERROR}: active WorkUnit #123 already owns job:#{job.id}"
      )
    )

    expect {
      described_class.perform_now(attempt.id)
    }.to have_enqueued_job(described_class).with(attempt.id)

    expect(attempt.reload.skipped_reason).to be_nil
    expect(attempt.performed_at).to be_nil
    expect(attempt.scheduled_at).to be > Time.current
    expect(workflow.reload).to be_failed
  end

  it "reschedules failed-step attempts before reopening when another active WorkUnit owns the job lock" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    workflow.work_unit.mark_terminal!("failed")
    owner_workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)

    expect {
      described_class.perform_now(attempt.id)
    }.to have_enqueued_job(described_class).with(attempt.id)

    expect(attempt.reload.skipped_reason).to be_nil
    expect(attempt.performed_at).to be_nil
    expect(attempt.scheduled_at).to be > Time.current
    expect(workflow.reload).to be_failed
    expect(owner_workflow.work_unit.reload).to be_queued
  end

  it "skips stale attempts after a newer workflow has already succeeded" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "succeeded",
      created_at: workflow.finished_at + 1.minute,
      started_at: workflow.finished_at + 1.minute,
      finished_at: workflow.finished_at + 2.minutes
    )
    job.update!(state: "implemented")
    allow(RetryWorkflowEnqueuer).to receive(:call)

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("source workflow was already superseded by a successful workflow")
    expect(attempt.performed_at).to be_nil
    expect(RetryWorkflowEnqueuer).not_to have_received(:call)
  end

  it "skips pending attempts for terminal jobs" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    job.update_columns(state: "closed", closure_reason: "pr_merged")
    allow(RetryWorkflowEnqueuer).to receive(:call)

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("job is terminal")
    expect(attempt.performed_at).to be_nil
    expect(RetryWorkflowEnqueuer).not_to have_received(:call)
  end

  it "skips stale provider-delay attempts when fresh classification no longer matches" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    run.update_columns(agent_outcome: nil)
    attempt.update!(failure_classification: "rate_limited")
    RunFailureClassification.create!(
      run: run,
      classification: "rate_limited",
      retryable: true,
      confidence: 0.9,
      reason: "stale deployed classifier result",
      classified_at: 20.minutes.ago
    )
    RunDiagnostic.create!(
      run: run,
      error_class: "GitRunner::GitError",
      error_message: "fatal: ambiguous argument 'HEAD': unknown revision or path not in the working tree."
    )

    expect {
      described_class.perform_now(attempt.id)
    }.not_to change { step.runs.count }

    expect(attempt.reload.skipped_reason).to eq("failure classification changed from rate_limited to git_state_corrupt before retry")
    expect(attempt.performed_at).to be_nil
    expect(run.run_failure_classification.reload.classification).to eq("git_state_corrupt")
  end

  it "skips stale usage-limit attempts when a default-provider job now resolves to another provider" do
    attempt = failed_attempt!(retry_kind: "failed_step")
    attempt.update!(failure_classification: ProviderUsageLimit::CLASSIFICATION, scheduled_at: 1.hour.from_now)
    job.update!(job_provider_setting: "default")
    job.user.update_columns(agent_provider: "codex", codex_api_key: "ck-test")
    allow(WorkEngine::Reconciler).to receive(:request)
    allow(RetryFailedStepEnqueuer).to receive(:call)

    described_class.perform_now(attempt.id)

    expect(attempt.reload.skipped_reason).to eq("default provider changed from claude to codex; reconciler will retry with codex")
    expect(attempt.performed_at).to be_nil
    expect(RetryFailedStepEnqueuer).not_to have_received(:call)
    expect(WorkEngine::Reconciler).to have_received(:request).with(source: "AutoRetryJob", job: job)
  end

  it "reschedules the same attempt when the provider circuit is still open" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    retry_after = 10.minutes.from_now
    open_circuit = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider transient failures",
      retry_after: retry_after,
      failure_count: 5,
      job_count: 3,
      signature: nil
    )
    allow(ProviderCircuitBreaker).to receive(:call).and_return(open_circuit)

    expect {
      described_class.perform_now(attempt.id)
    }.to have_enqueued_job(described_class).with(attempt.id)

    expect(attempt.reload.scheduled_at.to_i).to eq(retry_after.to_i)
    expect(attempt.skipped_reason).to be_nil
    expect(attempt.performed_at).to be_nil
    expect(job.workflows.count).to eq(1)
  end

  it "reschedules the same attempt when RetryWorkflowEnqueuer returns a circuit-open result" do
    attempt = failed_attempt!(retry_kind: "retry_workflow")
    retry_after = 10.minutes.from_now
    open_circuit = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider transient failures",
      retry_after: retry_after,
      failure_count: 5,
      job_count: 3,
      signature: nil
    )
    closed_circuit = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: false,
      reason: "provider healthy",
      retry_after: nil,
      failure_count: 0,
      job_count: 0,
      signature: nil
    )
    allow(ProviderCircuitBreaker).to receive(:call).and_return(closed_circuit)
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
      RetryWorkflowEnqueuer::Result.new(
        workflow: nil,
        error: "Claude appears degraded until #{retry_after.to_fs(:db)}; automatic retries are paused.",
        circuit: open_circuit
      )
    )

    expect {
      described_class.perform_now(attempt.id)
    }.to have_enqueued_job(described_class).with(attempt.id)

    expect(attempt.reload.scheduled_at.to_i).to eq(retry_after.to_i)
    expect(attempt.skipped_reason).to be_nil
    expect(attempt.performed_at).to be_nil
    expect(job.workflows.count).to eq(1)
  end
end

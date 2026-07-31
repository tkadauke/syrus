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

  def fail_workflow!(agent_outcome: "worker_died", cleaned_up: false)
    run.update_columns(state: "failed", agent_outcome: agent_outcome, agent_provider: "claude", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: (Time.current if cleaned_up))
    job.update_columns(state: "failed")
  end

  def enable_unified_work_engine_reconciler!
    Feature.find_or_create_by!(slug: WorkEngine::Gate::FEATURE_SLUG) do |feature|
      feature.category = "Operations"
      feature.name = "Unified work-engine reconciler"
    end.update!(enabled: true)
  end

  it "delegates to the unified reconciler without scheduling auto-retries when that gate is enabled" do
    enable_unified_work_engine_reconciler!
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
      .to eq("auto-retry skipped: unified work-engine reconciler is enabled")
  end

  it "schedules a delayed failed-step retry for retryable failures with workspace available" do
    freeze_time do
      fail_workflow!

      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.to change { AutoRetryAttempt.count }.by(1)
        .and have_enqueued_job(AutoRetryJob)

      attempt = AutoRetryAttempt.last
      expect(attempt).to have_attributes(
        job_id: job.id,
        workflow_id: workflow.id,
        run_id: run.id,
        agent_provider: "claude",
        failure_classification: "worker_died",
        retry_kind: "failed_step",
        attempt_number: 1,
        scheduled_at: described_class::WORKER_DIED_BACKOFF.from_now
      )
    end
  end

  it "schedules an in-place failed-step resume for retryable agentic failures with a captured session" do
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
      session_id: "claude-session-1",
      transcript_jsonl: "{}\n"
    )
    agent_step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")

    freeze_time do
      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.to change { AutoRetryAttempt.count }.by(1)
        .and have_enqueued_job(AutoRetryJob)

      attempt = AutoRetryAttempt.last
      expect(attempt).to have_attributes(
        job_id: job.id,
        workflow_id: workflow.id,
        run_id: agent_run.id,
        agent_provider: "claude",
        failure_classification: "worker_died",
        retry_kind: "resume_failed_step",
        attempt_number: 1,
        scheduled_at: described_class::WORKER_DIED_BACKOFF.from_now
      )
    end
  end

  it "falls back to failed-step retry for agentic failures without a captured session" do
    agent_step = workflow.steps.find_by!(kind: "implement")
    agent_run = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "failed",
      agent_outcome: "worker_died",
      finished_at: Time.current
    )
    agent_step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    job.update_columns(state: "failed")

    described_class.schedule_for_workflow(workflow: workflow)

    attempt = AutoRetryAttempt.last
    expect(attempt.run_id).to eq(agent_run.id)
    expect(attempt.retry_kind).to eq("failed_step")
  end

  it "does not schedule non-retryable failures" do
    fail_workflow!(agent_outcome: "error_max_turns")

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "caps attempts per job provider and failure classification for regular failures" do
    fail_workflow!(agent_outcome: "error_during_execution")
    3.times do |i|
      AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: run,
        agent_provider: "claude",
        failure_classification: "error_during_execution",
        retry_kind: "failed_step",
        attempt_number: i + 1,
        scheduled_at: Time.current
      )
    end

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "does not schedule a duplicate while an attempt is already pending" do
    fail_workflow!
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "failed_step",
      attempt_number: 1,
      scheduled_at: 5.minutes.from_now
    )

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "falls back to a retry workflow when the failed workspace is gone" do
    fail_workflow!(cleaned_up: true)

    described_class.schedule_for_workflow(workflow: workflow)

    attempt = AutoRetryAttempt.last
    expect(attempt.retry_kind).to eq("retry_workflow")
  end

  it "skips auto-retry without consuming budget when the workflow has a main_broken artifact" do
    fail_workflow!
    workflow.update!(artifacts: { "main_broken" => true })

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "schedules normally when main_broken artifact is absent" do
    fail_workflow!

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.to change { AutoRetryAttempt.count }.by(1)
  end

  describe "worker_died retry budget" do
    it "uses WORKER_DIED_BACKOFF for every worker_died attempt regardless of attempt number" do
      fail_workflow!
      # Simulate several prior worker_died attempts already consumed
      5.times do |i|
        AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: "claude",
          failure_classification: "worker_died",
          retry_kind: "failed_step",
          attempt_number: i + 1,
          scheduled_at: Time.current,
          performed_at: Time.current
        )
      end

      freeze_time do
        expect {
          described_class.schedule_for_workflow(workflow: workflow)
        }.to change { AutoRetryAttempt.count }.by(1)

        attempt = AutoRetryAttempt.last
        expect(attempt.scheduled_at).to eq(described_class::WORKER_DIED_BACKOFF.from_now)
        expect(attempt.attempt_number).to eq(6)
      end
    end

    it "continues scheduling worker_died retries past MAX_ATTEMPTS" do
      fail_workflow!
      described_class::MAX_ATTEMPTS.times do |i|
        AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: "claude",
          failure_classification: "worker_died",
          retry_kind: "failed_step",
          attempt_number: i + 1,
          scheduled_at: Time.current,
          performed_at: Time.current
        )
      end

      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.to change { AutoRetryAttempt.count }.by(1)
    end

    it "stops worker_died retries after MAX_WORKER_DIED_ATTEMPTS" do
      fail_workflow!
      described_class::MAX_WORKER_DIED_ATTEMPTS.times do |i|
        AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: "claude",
          failure_classification: "worker_died",
          retry_kind: "failed_step",
          attempt_number: i + 1,
          scheduled_at: Time.current,
          performed_at: Time.current
        )
      end

      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.not_to change { AutoRetryAttempt.count }
    end

    it "tracks worker_died and regular failure budgets independently" do
      # Exhaust the regular budget with non-worker_died failures
      3.times do |i|
        AutoRetryAttempt.create!(
          job: job,
          workflow: workflow,
          run: run,
          agent_provider: "claude",
          failure_classification: "error_during_execution",
          retry_kind: "failed_step",
          attempt_number: i + 1,
          scheduled_at: Time.current,
          performed_at: Time.current
        )
      end

      # A worker_died failure on the same job should still be schedulable
      fail_workflow!

      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.to change { AutoRetryAttempt.count }.by(1)

      attempt = AutoRetryAttempt.last
      expect(attempt.failure_classification).to eq("worker_died")
      expect(attempt.attempt_number).to eq(1)
    end
  end
end

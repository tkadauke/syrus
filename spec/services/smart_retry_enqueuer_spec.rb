require "rails_helper"

RSpec.describe SmartRetryEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, agent_provider: "claude", auto_merge_enabled: true) }

  def provider_decision(provider:, open: false)
    ProviderCircuitBreaker::Decision.new(
      provider: provider,
      open: open,
      reason: open ? "provider transient failures" : nil,
      retry_after: open ? 10.minutes.from_now : nil,
      failure_count: open ? 5 : 0,
      job_count: open ? 3 : 0,
      signature: nil
    )
  end

  def stub_provider_circuits(open_provider: nil)
    allow(ProviderCircuitBreaker).to receive(:call) do |provider|
      provider = provider.to_s
      provider_decision(provider: provider, open: provider == open_provider.to_s)
    end
  end

  def failed_job(state: "failed", trigger_kind: "initial", step_kind: "grader", provider: "claude", cleaned_up_at: nil, landing_failure_reason: nil)
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: state,
      issue_number: SecureRandom.random_number(9_999) + 1,
      agent_provider: provider,
      landing_failure_reason: landing_failure_reason
    )
    workflow = Workflow.create!(
      job: job,
      trigger_kind: trigger_kind,
      agent_provider: provider,
      started_at: 10.minutes.ago,
      finished_at: 1.minute.ago
    )
    workflow.update_columns(state: "failed", cleaned_up_at: cleaned_up_at)
    step = Step.create!(workflow: workflow, kind: step_kind, position: 1)
    step.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: trigger_kind,
      state: "failed",
      agent_provider: provider,
      agent_outcome: "worker_died",
      finished_at: 8.minutes.ago
    )

    [ job.reload, workflow.reload, step.reload, run.reload ]
  end

  before do
    stub_provider_circuits
  end

  it "chooses the narrowest retry action for mixed failed jobs" do
    grader_job, = failed_job(step_kind: "grader")
    worker_died_job, = failed_job(step_kind: "implement")
    fallback_job, fallback_workflow = failed_job(step_kind: "implement", cleaned_up_at: 1.minute.ago)
    landing_job, landing_workflow = failed_job(
      state: "implemented",
      trigger_kind: "auto_merge",
      step_kind: "auto_merge",
      landing_failure_reason: "auto_merge: required grader failed"
    )

    expect {
      result = described_class.call_many(jobs: [ grader_job, worker_died_job, fallback_job, landing_job ], automatic: true, by_user: user)

      expect(result.action_summary).to eq(
        "failed step retried" => 2,
        "implementation retried" => 1,
        "landing retried" => 1
      )
      expect(result.skipped_by_reason).to eq({})
      expect(result.affected_job_ids).to contain_exactly(grader_job.id, worker_died_job.id, fallback_job.id, landing_job.id)
    }.to change { fallback_job.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob).at_least(:once)

    expect(grader_job.latest_workflow.steps.first.reload).to be_queued
    expect(worker_died_job.latest_workflow.steps.first.reload).to be_queued
    expect(fallback_workflow.reload).to be_failed
    expect(landing_workflow.reload).to be_running
    expect(landing_workflow.steps.first.reload).to be_queued
    expect(landing_job.reload).to be_implemented
    expect(landing_job.landing_failure_reason).to be_nil
  end

  it "wakes the landing queue for an approved job with a landing failure" do
    job = Factories.job_record(
      user: user,
      repository: repository,
      state: "approved",
      pr_number: 10,
      landing_failure_reason: "auto_merge: required grader failed"
    )

    expect {
      result = described_class.call(job: job, automatic: true, by_user: user)

      expect(result).to be_success
      expect(result.action).to eq(:landing)
    }.to have_enqueued_job(LandingQueueProcessorJob)
  end

  it "wakes the landing queue for approved Epic children with a landing failure" do
    AppSetting.current.update!(merge_train_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    jobs = 3.times.map do |index|
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        state: "approved",
        issue_number: index + 1,
        pr_number: index + 10,
        branch_name: "syrus/issue-#{index + 1}",
        landing_failure_reason: "landing start blocked: stack dependencies not ready"
      )
    end

    merge_train_workflows_before = Workflow.where(trigger_kind: "merge_train").count
    merge_trains_before = MergeTrain.count

    expect {
      result = described_class.call(job: jobs.first, automatic: true, by_user: user)

      expect(result).to be_success
      expect(result.action).to eq(:landing)
      expect(result.workflow).to eq(jobs.first.latest_workflow)
    }.to have_enqueued_job(LandingQueueProcessorJob)

    expect(Workflow.where(trigger_kind: "merge_train").count).to eq(merge_train_workflows_before)
    expect(MergeTrain.count).to eq(merge_trains_before)
    expect(jobs.map { |job| job.reload.landing_failure_reason }).to all(be_nil)
    expect(jobs.map { |job| job.reload.state }).to all(eq("approved"))
  end

  it "resumes a failed agentic step when a captured session exists" do
    job, workflow, step, run = failed_job(step_kind: "implement")
    ClaudeSession.create!(resumable: run, session_id: "session-123", provider: "claude")

    result = described_class.call(job: job, automatic: true)

    expect(result).to be_success
    expect(result.action).to eq(:resume_failed_step)
    retry_run = step.runs.reorder(:created_at, :id).last
    expect(retry_run.parent_session_id).to eq("session-123")
    expect(retry_run.prompt).to eq(Prompts::Resume.new.to_s)
    expect(workflow.reload).to be_running
  end

  it "starts a fresh retry workflow for branch-diverged pr_open failures" do
    job, workflow, step, run = failed_job(step_kind: "pr_open")
    run.create_run_failure_classification!(
      classification: "branch_diverged",
      confidence: 0.95,
      retryable: false,
      reason: "The PR branch changed before Syrus could push this workflow.",
      classified_at: Time.current
    )

    expect {
      result = described_class.call(job: job, automatic: true)

      expect(result).to be_success
      expect(result.action).to eq(:implementation)
      expect(result.workflow).not_to eq(workflow)
      expect(result.workflow.trigger_kind).to eq("retry")
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)
      .and have_enqueued_job(RunJob)

    expect(workflow.reload).to be_failed
    expect(step.reload).to be_failed
  end

  it "skips active runs and provider circuits with explicit reasons" do
    active_job, = failed_job
    active_job.latest_workflow.steps.first.runs.create!(
      job: active_job,
      trigger_kind: "initial",
      state: "queued",
      agent_provider: "claude"
    )
    circuit_job, = failed_job(provider: "codex")
    stub_provider_circuits(open_provider: "codex")

    result = described_class.call_many(jobs: [ active_job, circuit_job ], automatic: true)

    expect(result).not_to be_success
    expect(result.skipped_by_reason).to eq(active_run: 1, provider_circuit: 1)
    expect(result.skip_summary).to eq("active run" => 1, "provider circuit" => 1)
  end

  it "skips closed, approved, and no-change-needed jobs" do
    closed = Factories.job_record(user: user, repository: repository, state: "closed")
    approved = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 10)
    no_change = Factories.job_record(user: user, repository: repository, state: "no_change_needed")

    result = described_class.call_many(jobs: [ closed, approved, no_change ], automatic: true)

    expect(result).not_to be_success
    expect(result.skipped_by_reason).to eq(closed: 1, approved: 1, no_change_needed: 1)
  end

  it "skips jobs whose PR is already current and passing" do
    ready_job, = failed_job
    ready_job.update!(
      pr_number: 77,
      branch_name: "syrus/direct-ready",
      commits_behind_base: 0,
      pr_checks_state: "passing"
    )

    result = described_class.call(job: ready_job, automatic: true)

    expect(result).not_to be_success
    expect(result.reason).to eq(:pr_ready)
  end
end

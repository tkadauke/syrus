require "rails_helper"

RSpec.describe WorkEngine::Reconciler do
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

  def reconcile(**attrs)
    described_class.call(source: "spec", **attrs)
  end

  def reconcile_and_execute(**attrs)
    described_class.call(source: "spec", execute_repairs: true, **attrs)
  end

  def kind(result, name)
    result.issues.find { |issue| issue.kind == name.to_s }
  end

  def plan(result, action)
    result.repair_plans.find { |repair_plan| repair_plan.action == action.to_s }
  end

  def solid_queue_run_job(run, claimed: false, failed: false, ready: false, run_at: nil, queue_name: "runs", error: "worker process failed", process_id: nil, created_at: 10.minutes.ago)
    ensure_solid_queue_test_tables!
    queue_job = SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: queue_name,
      priority: 10,
      arguments: { "arguments" => [ run.id ] },
      scheduled_at: run_at,
      created_at: created_at,
      updated_at: created_at
    )
    if ready
      SolidQueue::ReadyExecution.create!(
        job: queue_job,
        priority: queue_job.priority,
        queue_name: queue_job.queue_name,
        created_at: created_at
      )
    end
    if run_at
      SolidQueue::ScheduledExecution.create!(
        job: queue_job,
        priority: queue_job.priority,
        queue_name: queue_job.queue_name,
        scheduled_at: run_at,
        created_at: created_at
      )
    end
    if claimed
      process_id ||= SolidQueue::Process.create!(
        hostname: "worker-1",
        kind: "worker",
        last_heartbeat_at: created_at,
        metadata: {},
        name: "worker-1:1",
        pid: 123,
        created_at: created_at
      ).id
      SolidQueue::ClaimedExecution.create!(
        job: queue_job,
        process_id: process_id,
        created_at: created_at
      )
    end
    SolidQueue::FailedExecution.create!(job: queue_job, error: error, created_at: created_at) if failed
    queue_job
  end

  def live_worker_queue!(queue_name, hostname: "worker-live")
    ensure_solid_queue_test_tables!
    SolidQueue::Process.create!(
      hostname: hostname,
      kind: "worker",
      last_heartbeat_at: Time.current,
      metadata: { "queues" => [ queue_name, "runs" ] },
      name: "#{hostname}:1",
      pid: 321,
      created_at: Time.current
    )
  end

  before do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  after do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  it "returns a structured result and snapshot without mutating state" do
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)

    result = reconcile(run_id: run.id)

    expect(result).to be_a(described_class::Result)
    expect(result.snapshot.run_ids).to include(run.id)
    expect(result.snapshot.solid_queue_available).to eq(false)
    expect(result.repair_plans).to eq([])
    expect(run.reload.state).to eq("queued")
  end

  it "classifies a queued Run with no SolidQueue claim" do
    ensure_solid_queue_test_tables!
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)

    result = reconcile(run_id: run.id)
    issue = kind(result, :queued_run_without_queue_claim)

    expect(issue).to have_attributes(
      severity: "error",
      safe_to_auto_repair: true,
      recommended_repair_action: "reenqueue_run"
    )
    expect(issue.affected_ids[:run_ids]).to eq([ run.id ])
    expect(issue.evidence["solid_queue_state"]).to eq("missing")
    expect(plan(result, :reenqueue_run)).to have_attributes(
      auto_executable: true,
      target_type: "Run",
      target_id: run.id,
      execution_steps: [ "Run#reenqueue!" ]
    )
  end

  it "classifies a queued retry Run inside a running Workflow that has previous Runs" do
    ensure_solid_queue_test_tables!
    run.update_columns(state: "failed", finished_at: 6.minutes.ago)
    retry_run = step.runs.create!(
      job: job,
      user: job.user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago
    )
    clear_solid_queue_test_tables!
    workflow.update_columns(state: "running", started_at: 6.minutes.ago)
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)
    issue = result.issues.find do |candidate|
      candidate.kind == "queued_run_without_queue_claim" &&
        candidate.affected_ids[:run_ids] == [ retry_run.id ]
    end

    expect(issue).to be_present
    expect(issue.safe_to_auto_repair).to eq(true)
    expect(plan(result, :reenqueue_run)).to have_attributes(target_id: retry_run.id)
  end

  it "classifies a queued Run ready on a dead storage-affinity resume queue" do
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_storage_key: "storage-dead")
    solid_queue_run_job(run, ready: true, queue_name: "resume-storage-dead", created_at: 5.minutes.ago)

    result = reconcile(run_id: run.id)
    issue = kind(result, :queued_run_on_dead_resume_queue)

    expect(issue).to have_attributes(
      severity: "error",
      safe_to_auto_repair: true,
      recommended_repair_action: "reenqueue_run"
    )
    expect(issue.evidence["solid_queue_state"]).to eq("dead_resume_queue")
    expect(plan(result, :reenqueue_run)).to have_attributes(
      auto_executable: true,
      target_type: "Run",
      target_id: run.id
    )
  end

  it "does not re-enqueue a queued inline successor while the root RunJob is still claimed" do
    ensure_solid_queue_test_tables!
    run.update_columns(state: "succeeded", finished_at: 6.minutes.ago)
    successor = step.runs.create!(
      job: job,
      user: job.user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider,
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago
    )
    workflow.update_columns(state: "running", started_at: 6.minutes.ago)
    step.update_columns(state: "queued")
    solid_queue_run_job(run, claimed: true, created_at: 5.minutes.ago)

    result = reconcile(workflow_id: workflow.id)
    affected_run_ids = result.issues
      .select { |issue| issue.kind.start_with?("queued_run_") }
      .flat_map { |issue| issue.affected_ids.fetch(:run_ids, []) }

    expect(affected_run_ids).not_to include(successor.id)
  end

  it "does not repair a queued Run when a healthy queue job exists beside stale failed queue jobs" do
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_storage_key: "storage-dead")
    solid_queue_run_job(run, ready: true, queue_name: "resume-storage-dead", created_at: 5.minutes.ago)
    solid_queue_run_job(run, ready: true, queue_name: "runs", created_at: 4.minutes.ago)

    result = reconcile(run_id: run.id)

    expect(kind(result, :queued_run_on_dead_resume_queue)).to be_nil
    expect(kind(result, :queued_run_solid_queue_failed_execution)).to be_nil
    expect(result.repair_plans.select { |repair_plan| repair_plan.action == "reenqueue_run" }).to be_empty
  end

  it "cancels active workflows on closed jobs in the global reconciliation scope" do
    ensure_solid_queue_test_tables!
    workflow.update_columns(state: "running", started_at: 45.minutes.ago)
    step.update_columns(state: "running", started_at: 45.minutes.ago)
    run.update_columns(state: "running", started_at: 45.minutes.ago, last_heartbeat_at: 40.minutes.ago)
    job.update_columns(state: "closed", finished_at: 30.minutes.ago, closure_reason: "operator_cancelled")
    solid_queue_run_job(run, claimed: true, created_at: 45.minutes.ago)

    result = reconcile_and_execute

    expect(kind(result, :closed_job_active_workflow)).to have_attributes(
      severity: "critical",
      safe_to_auto_repair: true,
      recommended_repair_action: "cancel_workflow_for_closed_job"
    )
    expect(kind(result, :running_run_without_live_worker_evidence)).to be_nil
    expect(plan(result, :cancel_workflow_for_closed_job)).to have_attributes(
      auto_executable: true,
      target_type: "Workflow",
      target_id: workflow.id
    )
    expect(result.repair_executions.map(&:message)).to include("cancelled Workflow ##{workflow.id} because Job ##{job.id} is closed")
    expect(workflow.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(run.reload).to be_cancelled
  end

  it "cancels stale queued auto-retry workflows after a newer workflow succeeds" do
    source = workflow
    run.update_columns(state: "failed", agent_outcome: "worker_died", finished_at: 30.minutes.ago)
    step.update_columns(state: "failed", finished_at: 30.minutes.ago)
    source.update_columns(state: "failed", finished_at: 30.minutes.ago)

    successful = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "succeeded",
      created_at: 25.minutes.ago,
      started_at: 25.minutes.ago,
      finished_at: 20.minutes.ago
    )
    job.update!(state: "implemented")

    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: source,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 2,
      scheduled_at: 10.minutes.ago,
      performed_at: 9.minutes.ago
    )
    stale = Workflows::Retry.instantiate(
      job: job,
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      agent_provider: "claude"
    )
    stale.update_columns(created_at: 9.minutes.ago)
    StepDispatcher.start_workflow(stale)
    stale.reload
    stale.first_step.runs.first.update_columns(created_at: 9.minutes.ago, updated_at: 9.minutes.ago)

    result = nil
    expect {
      result = reconcile_and_execute(job_id: job.id)
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "WorkEngine::RepairExecutor::Policies::CancelStaleAutoRetryWorkflow",
      job_id: job.id,
      workflow_id: nil,
      run_id: nil
    )
    issue = kind(result, :stale_auto_retry_workflow)

    expect(issue).to be_present
    expect(kind(result, :queued_run_without_queue_claim)).to be_nil
    expect(plan(result, :reenqueue_run)).to be_nil
    expect(plan(result, :cancel_stale_auto_retry_workflow)).to have_attributes(
      auto_executable: true,
      target_type: "Workflow",
      target_id: stale.id
    )
    expect(result.repair_executions.map(&:message)).to include("cancelled stale auto-retry Workflow ##{stale.id}")
    expect(stale.reload).to be_cancelled
    expect(stale.first_step.runs.first.reload).to be_cancelled
    expect(attempt.reload.skipped_reason).to eq("source workflow was already superseded")
  end

  it "cancels stale queued auto-retry workflows when the source workflow itself later succeeded" do
    source = workflow
    source.update_columns(state: "succeeded", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
    step.update_columns(state: "succeeded", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
    run.update_columns(state: "succeeded", started_at: 20.minutes.ago, finished_at: 10.minutes.ago)
    job.update!(state: "implemented")

    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: source,
      run: run,
      agent_provider: "claude",
      failure_classification: "worker_died",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: 9.minutes.ago,
      performed_at: 8.minutes.ago
    )
    stale = Workflows::Retry.instantiate(
      job: job,
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      agent_provider: "claude"
    )
    stale.update_columns(created_at: 8.minutes.ago)
    StepDispatcher.start_workflow(stale)
    stale.reload
    stale.first_step.runs.first.update_columns(created_at: 8.minutes.ago, updated_at: 8.minutes.ago)

    result = reconcile_and_execute(job_id: job.id)

    expect(kind(result, :stale_auto_retry_workflow)).to be_present
    expect(kind(result, :queued_run_without_queue_claim)).to be_nil
    expect(plan(result, :reenqueue_run)).to be_nil
    expect(plan(result, :cancel_stale_auto_retry_workflow)).to have_attributes(target_id: stale.id)
    expect(stale.reload).to be_cancelled
    expect(stale.first_step.runs.first.reload).to be_cancelled
    expect(attempt.reload.skipped_reason).to eq("source workflow was already superseded")
  end

  it "cancels stale queued auto-retry workflows after branch divergence recovery supersedes the source" do
    source = workflow
    job.update!(
      state: "implemented",
      pr_number: 77,
      branch_name: "syrus/issue-42-#{job.id}",
      mergeability_head_sha: "remote-head"
    )
    source.update_columns(state: "failed", trigger_kind: "retry", finished_at: 10.minutes.ago)
    step.update_columns(kind: "pr_open", state: "failed", finished_at: 10.minutes.ago)
    run.update_columns(state: "failed", finished_at: 10.minutes.ago)
    run.create_run_failure_classification!(
      classification: "branch_diverged",
      retryable: false,
      confidence: 0.95,
      reason: "The PR branch changed before Syrus could push this workflow.",
      classified_at: 10.minutes.ago
    )
    source.set_artifact!("branch_divergence", {
      "branch" => job.branch_name,
      "remote_sha" => "remote-head",
      "local_sha" => "stale-local"
    })
    source.set_artifact!("branch_divergence_recovery", {
      "action" => "superseded_by_current_pr_branch",
      "at" => 9.minutes.ago.iso8601
    })

    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: source,
      run: run,
      agent_provider: "claude",
      failure_classification: "branch_diverged",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: 8.minutes.ago,
      performed_at: 7.minutes.ago
    )
    stale = Workflows::Retry.instantiate(
      job: job,
      artifacts: { "auto_retry_attempt_id" => attempt.id },
      agent_provider: "claude"
    )
    stale.update_columns(created_at: 7.minutes.ago)
    StepDispatcher.start_workflow(stale)
    stale.reload
    stale.first_step.runs.first.update_columns(created_at: 7.minutes.ago, updated_at: 7.minutes.ago)

    result = reconcile_and_execute(job_id: job.id)

    expect(kind(result, :stale_auto_retry_workflow)).to be_present
    expect(kind(result, :nonretryable_semantic_git_failure)).to be_nil
    expect(kind(result, :queued_run_without_queue_claim)).to be_nil
    expect(plan(result, :reenqueue_run)).to be_nil
    expect(plan(result, :cancel_stale_auto_retry_workflow)).to have_attributes(target_id: stale.id)
    expect(stale.reload).to be_cancelled
    expect(stale.first_step.runs.first.reload).to be_cancelled
    expect(attempt.reload.skipped_reason).to eq("source workflow was already superseded")
  end

  it "reconciles a queued Job with a cancelled latest retry once the PR is current, passing, and clean" do
    published = workflow
    published.update!(
      state: "succeeded",
      trigger_kind: "retry",
      started_at: 30.minutes.ago,
      finished_at: 25.minutes.ago,
      artifacts: { "publication_branch" => "syrus/direct-2415" }
    )
    step.update_columns(state: "succeeded", started_at: 30.minutes.ago, finished_at: 25.minutes.ago)
    run.update_columns(state: "succeeded", started_at: 30.minutes.ago, finished_at: 25.minutes.ago)
    failed = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "failed",
      started_at: 20.minutes.ago,
      finished_at: 15.minutes.ago
    )
    failed_step = failed.steps.create!(kind: "pr_open", position: 0, state: "failed")
    failed_step.runs.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "failed", finished_at: 15.minutes.ago)
    cancelled = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "cancelled",
      started_at: 5.minutes.ago,
      finished_at: 1.minute.ago,
      artifacts: { "retry_cancelled_reason" => "stale_auto_retry" }
    )
    cancelled.steps.create!(kind: "prepare", position: 0, state: "cancelled")
    job.update!(
      state: "queued",
      pr_number: 2174,
      branch_name: "syrus/direct-2415",
      pr_checks_state: "passing",
      commits_behind_base: 0,
      github_mergeable_state: "clean"
    )

    result = reconcile_and_execute(job_id: job.id)

    expect(kind(result, :unambiguous_job_state_drift)).to have_attributes(
      recommended_repair_action: "reconcile_job_state",
      safe_to_auto_repair: true
    )
    expect(plan(result, :reconcile_job_state)).to have_attributes(target_id: job.id)
    expect(job.reload).to be_implemented
    expect(job.latest_workflow).to eq(cancelled)
  end

  it "discards stale branch-diverged workflow output when the current PR head matches the protected remote SHA" do
    job.update!(
      state: "queued",
      pr_number: 77,
      branch_name: "syrus/issue-42-#{job.id}",
      mergeability_head_sha: "remote-head"
    )
    workflow.update_columns(state: "failed", trigger_kind: "retry", finished_at: 10.minutes.ago)
    step.update_columns(kind: "pr_open", state: "failed", finished_at: 10.minutes.ago)
    run.update_columns(state: "failed", finished_at: 10.minutes.ago)
    run.create_run_failure_classification!(
      classification: "branch_diverged",
      retryable: false,
      confidence: 0.95,
      reason: "The PR branch changed before Syrus could push this workflow.",
      classified_at: 10.minutes.ago
    )
    workflow.set_artifact!("branch_divergence", {
      "branch" => job.branch_name,
      "remote_sha" => "remote-head",
      "local_sha" => "stale-local"
    })
    newer = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "cancelled",
      created_at: 1.minute.ago,
      finished_at: 1.minute.ago
    )

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(kind(result, :stale_branch_diverged_workflow)).to have_attributes(
      severity: "info",
      safe_to_auto_repair: true,
      recommended_repair_action: "discard_superseded_branch_output"
    )
    expect(kind(result, :nonretryable_semantic_git_failure)).to be_nil
    expect(plan(result, :discard_superseded_branch_output)).to have_attributes(
      auto_executable: true,
      target_type: "Workflow",
      target_id: workflow.id
    )
    expect(result.repair_executions.map(&:message)).to include("discarded superseded branch output for Workflow ##{workflow.id}")
    expect(workflow.reload.artifact("branch_divergence_recovery")).to include(
      "action" => "superseded_by_current_pr_branch"
    )
    expect(job.reload).to be_queued
    expect(newer.reload).to be_cancelled
  end

  it "plans a fresh retry from the current PR branch for the latest failed branch divergence" do
    job.update!(
      state: "failed",
      pr_number: 77,
      branch_name: "syrus/issue-42-#{job.id}",
      mergeability_head_sha: "remote-head"
    )
    workflow.update_columns(state: "failed", trigger_kind: "retry", finished_at: 10.minutes.ago)
    step.update_columns(kind: "pr_open", state: "failed", finished_at: 10.minutes.ago)
    run.update_columns(state: "failed", finished_at: 10.minutes.ago, agent_provider: "claude")
    run.create_run_failure_classification!(
      classification: "branch_diverged",
      retryable: false,
      confidence: 0.95,
      reason: "The PR branch changed before Syrus could push this workflow.",
      classified_at: 10.minutes.ago
    )
    workflow.set_artifact!("branch_divergence", {
      "branch" => job.branch_name,
      "remote_sha" => "remote-head",
      "local_sha" => "stale-local"
    })

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(kind(result, :branch_diverged_pr_open)).to have_attributes(
      severity: "warning",
      safe_to_auto_repair: true,
      recommended_repair_action: "retry_workflow"
    )
    expect(kind(result, :nonretryable_semantic_git_failure)).to be_nil
    expect(plan(result, :retry_workflow)).to have_attributes(
      auto_executable: true,
      target_type: "Workflow",
      target_id: workflow.id
    )
    expect(AutoRetryAttempt.where(job: job, workflow: workflow, run: run, retry_kind: "retry_workflow")).to exist
    expect(enqueued_jobs.map { |entry| entry[:job] }).to include(AutoRetryJob)
  end

  it "does not re-enqueue a queued Run while a normal-queue RunJob is scheduled for retry" do
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_storage_key: "storage-dead")
    solid_queue_run_job(run, ready: true, queue_name: "resume-storage-dead", created_at: 5.minutes.ago)
    scheduled = solid_queue_run_job(run, run_at: 15.seconds.from_now, queue_name: "runs", created_at: Time.current)

    result = reconcile(run_id: run.id)

    expect(kind(result, :queued_run_on_dead_resume_queue)).to be_nil
    expect(kind(result, :queued_run_without_queue_claim)).to be_nil
    expect(result.snapshot.solid_queue_jobs.find { |job| job[:id] == scheduled.id }).to include(
      scheduled: true,
      scheduled_at: be_within(1.second).of(scheduled.scheduled_execution.scheduled_at)
    )
    expect(result.repair_plans.select { |repair_plan| repair_plan.action == "reenqueue_run" }).to be_empty
  end

  it "executes safe queued Run re-enqueue repairs when requested" do
    ensure_solid_queue_test_tables!
    run.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)

    result = nil
    expect {
      result = reconcile_and_execute(run_id: run.id)
    }.to have_enqueued_job(RunJob).with(run.id)

    expect(result.repair_executions.map(&:status)).to include("applied")
    expect(JobLog.where(run: run).pluck(:chunk)).to include(
      match(/\[work-engine reconciler\] applying reenqueue_run/),
      match(/\[work-engine reconciler\] applied reenqueue_run/)
    )
  end

  it "classifies a queued Run with a stale SolidQueue claim" do
    solid_queue_run_job(run, claimed: true, created_at: 15.minutes.ago)
    run.update_columns(state: "queued", created_at: 15.minutes.ago, updated_at: 15.minutes.ago)

    result = reconcile(run_id: run.id)
    issue = kind(result, :queued_run_stale_queue_claim)

    expect(issue.severity).to eq("warning")
    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.recommended_repair_action).to eq("check_queue_worker_or_wait")
    expect(plan(result, :diagnose_queue_starvation).auto_executable).to eq(false)
  end

  it "classifies a stale running Run without live worker evidence" do
    ensure_solid_queue_test_tables!
    run.update_columns(
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    )
    step.update_columns(state: "running", started_at: run.started_at)
    workflow.update_columns(state: "running", started_at: run.started_at)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    result = reconcile(run_id: run.id)
    issue = kind(result, :running_run_without_live_worker_evidence)

    expect(issue.severity).to eq("critical")
    expect(issue.safe_to_auto_repair).to eq(true)
    expect(issue.recommended_repair_action).to eq("fail_run_as_worker_died")
    expect(plan(result, :mark_worker_died_and_retry_failed_step)).to have_attributes(
      auto_executable: true,
      target_id: run.id
    )
    expect(run.reload.state).to eq("running")
  end

  it "auto-repairs a detached running Run after the short worker-evidence grace" do
    ensure_solid_queue_test_tables!
    heartbeat_at = 4.minutes.ago
    run.update_columns(
      state: "running",
      started_at: 10.minutes.ago,
      last_heartbeat_at: heartbeat_at
    )
    step.update_columns(state: "running", started_at: run.started_at)
    workflow.update_columns(state: "running", started_at: run.started_at)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    result = reconcile(run_id: run.id)
    issue = kind(result, :running_run_without_live_worker_evidence)

    expect(issue).to have_attributes(
      severity: "critical",
      safe_to_auto_repair: true,
      recommended_repair_action: "fail_run_as_worker_died",
      check_after: nil
    )
    expect(issue.evidence).to include(
      "detached_worker_evidence" => true,
      "detached_worker_evidence_grace_seconds" => 180
    )
    expect(plan(result, :mark_worker_died_and_retry_failed_step)).to have_attributes(
      auto_executable: true,
      target_id: run.id
    )
  end

  it "reports an accurate check_after for detached running Runs inside the short worker-evidence grace" do
    ensure_solid_queue_test_tables!
    heartbeat_at = 2.minutes.ago
    run.update_columns(
      state: "running",
      started_at: 10.minutes.ago,
      last_heartbeat_at: heartbeat_at
    )
    step.update_columns(state: "running", started_at: run.started_at)
    workflow.update_columns(state: "running", started_at: run.started_at)

    result = reconcile(run_id: run.id)
    issue = kind(result, :running_run_without_live_worker_evidence)

    expect(issue).to have_attributes(
      severity: "warning",
      safe_to_auto_repair: false,
      recommended_repair_action: "capture_diagnostics"
    )
    expect(issue.check_after).to be_within(1.second).of(heartbeat_at + described_class::DETACHED_WORKER_EVIDENCE_GRACE)
    expect(issue.evidence).to include("detached_worker_evidence" => true)
    expect(plan(result, :capture_run_diagnostics)).to have_attributes(auto_executable: false, target_id: run.id)
  end

  it "keeps active SolidQueue running Runs on the stale-heartbeat deadline" do
    ensure_solid_queue_test_tables!
    heartbeat_at = 4.minutes.ago
    solid_queue_run_job(run, claimed: true, created_at: 30.seconds.ago)
    run.update_columns(
      state: "running",
      started_at: 10.minutes.ago,
      last_heartbeat_at: heartbeat_at
    )
    step.update_columns(state: "running", started_at: run.started_at)
    workflow.update_columns(state: "running", started_at: run.started_at)

    result = reconcile(run_id: run.id)
    issue = kind(result, :running_run_without_live_worker_evidence)

    expect(issue).to have_attributes(
      severity: "warning",
      safe_to_auto_repair: false,
      recommended_repair_action: "capture_diagnostics"
    )
    expect(issue.check_after).to be_within(1.second).of(heartbeat_at + Run::STALE_HEARTBEAT_THRESHOLD)
    expect(issue.evidence).to include("detached_worker_evidence" => false)
  end

  it "plans session resume after a stale running agent Run loses its worker" do
    agent_step = workflow.steps.find_by!(kind: "implement")
    agent_run = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    )
    ClaudeSession.create!(resumable: agent_run, provider: "claude", session_id: "session-1", transcript_jsonl: "{}\n")
    agent_step.update_columns(state: "running", started_at: agent_run.started_at)
    workflow.update_columns(state: "running", started_at: agent_run.started_at)
    ensure_solid_queue_test_tables!

    result = reconcile(run_id: agent_run.id)
    repair_plan = plan(result, :mark_worker_died_and_resume_failed_step)

    expect(repair_plan).to have_attributes(auto_executable: true, target_id: agent_run.id)
    expect(repair_plan.execution_steps).to eq([ "Run#fail!(agent_outcome: worker_died)", "ResumeWorkflowEnqueuer.call" ])
    expect(agent_run.reload.state).to eq("running")
  end

  it "auto-fails a stale running grader Run when no retry path is available" do
    step.update_columns(kind: "grader", state: "running", started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago)
    workflow.update_columns(state: "running", started_at: step.started_at)
    run.update_columns(
      state: "running",
      started_at: step.started_at,
      last_heartbeat_at: step.started_at
    )
    ensure_solid_queue_test_tables!
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)

    result = nil
    expect {
      result = reconcile_and_execute(run_id: run.id)
    }.not_to change { AutoRetryAttempt.count }

    repair_plan = plan(result, :mark_worker_died)
    expect(repair_plan).to have_attributes(auto_executable: true, target_id: run.id)
    expect(repair_plan.execution_steps).to eq([ "Run#fail!(agent_outcome: worker_died)" ])
    expect(run.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
    expect(result.repair_executions.map(&:message)).to include(match(/no automatic retry was scheduled/))
    expect(JobLog.where(run: run).pluck(:chunk)).to include(match(/applied mark_worker_died: .*no automatic retry was scheduled/))
  end

  it "auto-fails a stale running prepare Run whose SolidQueue job failed with ProcessPrunedError" do
    step.update_columns(kind: "prepare", state: "running", started_at: 10.minutes.ago)
    workflow.update_columns(state: "running", started_at: step.started_at)
    run.update_columns(
      state: "running",
      started_at: step.started_at,
      last_heartbeat_at: 4.minutes.ago
    )
    solid_queue_run_job(run, failed: true, error: { exception_class: "SolidQueue::Processes::ProcessPrunedError" }.to_json)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)

    result = reconcile_and_execute(run_id: run.id)

    issue = kind(result, :running_run_without_live_worker_evidence)
    expect(issue.evidence.dig("solid_queue", "error")).to include("ProcessPrunedError")
    expect(plan(result, :mark_worker_died)).to have_attributes(auto_executable: true, target_id: run.id)
    expect(run.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
  end

  it "reconciles a running grader Step whose Run already failed and resumes the queued tail" do
    next_step = Step.create!(workflow: workflow, kind: "grader", position: 1)
    step.update!(kind: "grader", next_step: next_step)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)
    step.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)
    next_step.update_columns(state: "queued", started_at: nil, finished_at: nil)
    run.update_columns(
      state: "failed",
      started_at: 10.minutes.ago,
      last_heartbeat_at: 9.minutes.ago,
      finished_at: 8.minutes.ago
    )
    RunFailureClassification.create!(
      run: run,
      classification: "database_connection_error",
      retryable: true,
      confidence: 0.95,
      reason: "Too many connections",
      classified_at: 8.minutes.ago
    )

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(kind(result, :running_step_with_terminal_runs)).to be_present
    expect(kind(result, :retryable_run_failure)).to be_nil
    expect(plan(result, :reconcile_step_from_terminal_run)).to have_attributes(
      auto_executable: true,
      target_type: "Step",
      target_id: step.id
    )
    expect(step.reload).to be_failed
    expect(next_step.reload).to be_queued
    expect(next_step.runs.last).to have_attributes(state: "queued", job_id: job.id)
    expect(result.repair_executions.map(&:message)).to include("reconciled Step ##{step.id} to failed from Run ##{run.id}")
  end

  it "fails a running workflow that already has a failed step and a queued tail" do
    pr_open = Step.create!(workflow: workflow, kind: "pr_open", position: 1)
    step.update!(kind: "test_plan", next_step: pr_open)
    job.update_columns(state: "running", started_at: 30.minutes.ago)
    workflow.update_columns(state: "running", started_at: 30.minutes.ago, finished_at: nil)
    step.update_columns(state: "failed", started_at: 20.minutes.ago, finished_at: 15.minutes.ago)
    pr_open.update_columns(state: "queued", started_at: nil, finished_at: nil)
    run.update_columns(
      state: "failed",
      agent_provider: "codex",
      agent_outcome: "error",
      started_at: 20.minutes.ago,
      finished_at: 15.minutes.ago
    )
    RunFailureClassification.create!(
      run: run,
      classification: "agent_resume_unavailable",
      retryable: true,
      confidence: 0.9,
      reason: "provider resume session unavailable",
      classified_at: 15.minutes.ago
    )

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(kind(result, :running_workflow_with_failed_step)).to be_present
    expect(plan(result, :fail_workflow_from_failed_step)).to have_attributes(
      auto_executable: true,
      target_type: "Workflow",
      target_id: workflow.id
    )
    expect(workflow.reload).to be_failed
    expect(job.reload).to be_failed
    expect(step.reload).to be_failed
    expect(pr_open.reload).to be_queued
    expect(result.repair_executions.map(&:message)).to include("marked Workflow ##{workflow.id} failed from failed Step ##{step.id}")
  end

  it "reconciles a running Step whose only Run already succeeded" do
    next_step = Step.create!(workflow: workflow, kind: "grader_collect", position: 1)
    step.update!(kind: "grader", next_step: next_step)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago)
    step.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)
    next_step.update_columns(state: "queued", started_at: nil, finished_at: nil)
    run.update_columns(
      state: "succeeded",
      started_at: 10.minutes.ago,
      last_heartbeat_at: 9.minutes.ago,
      finished_at: 8.minutes.ago
    )

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(kind(result, :running_step_with_terminal_runs)).to be_present
    expect(plan(result, :reconcile_step_from_terminal_run)).to have_attributes(
      auto_executable: true,
      target_type: "Step",
      target_id: step.id
    )
    expect(step.reload).to be_succeeded
    expect(next_step.reload.runs.last).to have_attributes(state: "queued", job_id: job.id)
    expect(result.repair_executions.map(&:message)).to include("reconciled Step ##{step.id} to succeeded from Run ##{run.id}")
  end

  it "executes stale running agent session resume after marking worker_died" do
    agent_step = workflow.steps.find_by!(kind: "implement")
    agent_run = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    )
    ClaudeSession.create!(resumable: agent_run, provider: "claude", session_id: "session-1", transcript_jsonl: "{}\n")
    agent_step.update_columns(state: "running", started_at: agent_run.started_at)
    workflow.update_columns(state: "running", started_at: agent_run.started_at)
    ensure_solid_queue_test_tables!

    expect {
      reconcile_and_execute(run_id: agent_run.id)
    }.to change { AutoRetryAttempt.where(retry_kind: "resume_failed_step").count }.by(1)

    expect(agent_run.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
  end

  it "executes stale running workspace retry after marking worker_died" do
    ensure_solid_queue_test_tables!
    agent_step = workflow.steps.find_by!(kind: "implement")
    agent_run = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    )
    agent_step.update_columns(state: "running", started_at: agent_run.started_at)
    workflow.update_columns(state: "running", started_at: agent_run.started_at)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    expect {
      reconcile_and_execute(run_id: agent_run.id)
    }.to change { AutoRetryAttempt.where(retry_kind: "failed_step").count }.by(1)

    expect(agent_run.reload).to have_attributes(state: "failed", agent_outcome: "worker_died")
  end

  it "does not fail a detached Run inside grace or a Run with a live spawned process" do
    fresh = step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: 30.seconds.ago
    )
    live_step = workflow.steps.find_by!(kind: "implement")
    live = live_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "running",
      started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
      last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    )
    SpawnedProcess.create!(
      run: live,
      workflow: workflow,
      kind: "agent",
      command: "codex exec",
      hostname: "worker-1",
      started_at: 5.minutes.ago
    )
    step.update_columns(state: "running", started_at: fresh.started_at)
    live_step.update_columns(state: "running", started_at: live.started_at)
    workflow.update_columns(state: "running", started_at: live.started_at)

    result = reconcile_and_execute(workflow_id: workflow.id)

    affected_run_ids = result.issues
      .select { |issue| issue.kind == "running_run_without_live_worker_evidence" }
      .flat_map { |issue| issue.affected_ids.fetch(:run_ids, []) }
    expect(affected_run_ids).to include(fresh.id)
    expect(affected_run_ids).not_to include(live.id)
    expect(fresh.reload.state).to eq("running")
    expect(live.reload.state).to eq("running")
  end

  it "classifies a queued Workflow without a first Run" do
    run.destroy!
    workflow.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :queued_workflow_without_first_run)

    expect(issue.safe_to_auto_repair).to eq(true)
    expect(issue.recommended_repair_action).to eq("start_workflow")
    expect(plan(result, :start_workflow)).to have_attributes(auto_executable: true, target_id: workflow.id)
  end

  it "classifies explicit dependency or stack start blocks as wait-only" do
    run.destroy!
    prerequisite = Factories.job(repository: job.repository, issue_number: 99)
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
    workflow.update_columns(
      state: "queued",
      artifacts: {
        "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :dependency_stack_start_block)

    expect(issue.severity).to eq("info")
    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.recommended_repair_action).to eq("wait_for_dependency_or_stack_readiness")
    expect(issue.check_after).to be_present
    expect(issue.evidence.fetch("unsatisfied_dependencies")).to be_present
    expect(plan(result, :wait_for_dependency_or_stack_readiness).auto_executable).to eq(false)
  end

  it "rechecks expired dependency or stack start blocks by starting the workflow again" do
    run.destroy!
    workflow.update_columns(
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
        "start_blocked_next_check_at" => 1.minute.ago.iso8601
      }
    )
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)

    expect(kind(result, :dependency_stack_start_block)).to be_nil
    expect(kind(result, :queued_workflow_without_first_run)).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "start_workflow"
    )
    expect(plan(result, :start_workflow)).to have_attributes(auto_executable: true, target_id: workflow.id)
  end

  it "classifies a stale dependency start block as repairable when dependencies are satisfied" do
    run.destroy!
    workflow.update_columns(
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :stale_dependency_start_block)

    expect(issue.safe_to_auto_repair).to eq(true)
    expect(issue.recommended_repair_action).to eq("clear_stale_start_block_and_start_workflow")
    expect(issue.evidence.fetch("unsatisfied_dependencies")).to eq([])
    expect(kind(result, :dependency_stack_start_block)).to be_nil
    expect(kind(result, :queued_workflow_without_first_run)).to be_nil
    expect(plan(result, :clear_stale_start_block_and_start_workflow)).to have_attributes(auto_executable: true, target_id: workflow.id)
  end

  it "repairs a stale dependency start block by clearing it and starting the workflow" do
    run.destroy!
    workflow.update_columns(
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )
    step.update_columns(state: "queued")

    result = reconcile_and_execute(workflow_id: workflow.id)

    expect(plan(result, :clear_stale_start_block_and_start_workflow)).to have_attributes(auto_executable: true, target_id: workflow.id)
    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
    expect(step.runs.count).to eq(1)
  end

  it "classifies main-health start blocks with the matching wait-only action" do
    run.destroy!
    job.repository.update!(ci_health: "broken", landing_paused: true)
    workflow.update_columns(
      state: "queued",
      artifacts: {
        "start_blocked_reason" => StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :main_health_start_block)

    expect(issue.severity).to eq("info")
    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.recommended_repair_action).to eq("wait_for_main_health")
    expect(plan(result, :wait_for_main_health).auto_executable).to eq(false)
  end

  it "classifies workflow admission budget start blocks as resource admission, not main health" do
    run.destroy!
    workflow.update_columns(
      state: "queued",
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601,
        "start_blocked_details" => { "reason" => "predicted_budget_pressure_high" }
      }
    )

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :resource_admission_start_block)

    expect(issue.severity).to eq("info")
    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.recommended_repair_action).to eq("wait_for_resource_admission")
    expect(kind(result, :main_health_start_block)).to be_nil
    expect(plan(result, :wait_for_resource_admission).auto_executable).to eq(false)
  end

  it "ignores stale main-health start blocks after repository health recovers" do
    run.destroy!
    job.repository.update!(ci_health: "healthy", grader_health: "healthy", landing_paused: false)
    workflow.update_columns(
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)

    expect(kind(result, :main_health_start_block)).to be_nil
    expect(kind(result, :queued_workflow_without_first_run)).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "start_workflow"
    )
  end

  it "ignores stale main-broken workflow artifacts after repository health recovers" do
    job.repository.update!(ci_health: "healthy", grader_health: "healthy", landing_paused: false)
    workflow.update_columns(
      state: "failed",
      finished_at: Time.current,
      artifacts: { "main_broken" => true }
    )

    result = reconcile(workflow_id: workflow.id)

    expect(kind(result, :main_branch_broken)).to be_nil
  end

  it "classifies Job/Workflow state drift" do
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    job.update_columns(state: "failed")

    result = reconcile(job_id: job.id)
    issue = kind(result, :job_workflow_state_drift)

    expect(issue.recommended_repair_action).to eq("operator_review_state_transition")
    expect(issue.affected_ids[:workflow_ids]).to include(workflow.id)
  end

  it "auto-defers a landing Job that has no active Workflow" do
    workflow.update_columns(state: "succeeded", finished_at: 1.minute.ago)
    step.update_columns(state: "succeeded", finished_at: 1.minute.ago)
    run.update_columns(state: "succeeded", finished_at: 1.minute.ago)
    job.update!(state: "landing", approved_at: 2.minutes.ago, approved_via: "operator")

    result = reconcile(job_id: job.id)
    issue = kind(result, :landing_job_without_active_workflow)

    expect(issue).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "defer_orphaned_landing_job"
    )
    expect(plan(result, :defer_orphaned_landing_job)).to have_attributes(auto_executable: true, target_id: job.id)

    executed = reconcile_and_execute(job_id: job.id)

    expect(plan(executed, :defer_orphaned_landing_job)).to be_present
    expect(job.reload).to be_approved
  end

  it "classifies and repairs landing workflows queued without a first Run by admission blocking" do
    landing_job = Factories.job_record(
      user: job.user,
      repository: job.repository,
      state: "landing",
      issue_number: 2242,
      pr_number: 2181,
      branch_name: "syrus/issue-2242",
      pr_checks_state: "passing",
      github_mergeable_state: "clean",
      github_mergeable: true,
      local_mergeable: true,
      local_mergeable_state: "clean",
      commits_behind_base: 0,
      approved_at: 2.minutes.ago,
      approved_via: "operator"
    )
    auto_merge = Workflows::AutoMerge.instantiate(job: landing_job)
    auto_merge.update_columns(
      state: "queued",
      created_at: 5.minutes.ago,
      updated_at: 5.minutes.ago,
      artifacts: {
        "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
        "start_blocked_details" => {
          "action" => "delay_until",
          "reason" => "predicted_budget_pressure_high"
        },
        "start_blocked_next_check_at" => 3.minutes.from_now.iso8601
      }
    )

    result = reconcile(workflow_id: auto_merge.id)
    issue = kind(result, :landing_start_blocked)

    expect(issue).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "defer_landing_start_blocked_workflow"
    )
    expect(issue.evidence).to include(
      "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
      "landing_queue_entry" => include("position" => 1, "blocked_reason" => nil)
    )
    expect(kind(result, :main_health_start_block)).to be_nil
    expect(kind(result, :queued_workflow_without_first_run)).to be_nil
    expect(plan(result, :defer_landing_start_blocked_workflow)).to have_attributes(auto_executable: true, target_id: auto_merge.id)

    executed = reconcile_and_execute(workflow_id: auto_merge.id)

    expect(plan(executed, :defer_landing_start_blocked_workflow)).to be_present
    expect(auto_merge.reload).to be_failed
    expect(auto_merge.failure_reason).to eq("landing start blocked: workflow admission budget")
    expect(landing_job.reload).to be_approved
    expect(landing_job.landing_failure_reason).to eq("landing start blocked: workflow admission budget")
  end

  it "clears approved landing-start blockers and wakes the landing queue" do
    AppSetting.current.update!(merge_train_enabled: true)
    epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
    primary = Factories.job_record(user: job.user, repository: job.repository, epic: epic, state: "approved", issue_number: 1, pr_number: 101, branch_name: "syrus/issue-1")
    blocked = [
      primary,
      Factories.job_record(user: job.user, repository: job.repository, epic: epic, state: "approved", issue_number: 2, pr_number: 102, branch_name: "syrus/issue-2")
    ]
    blocked.each_with_index do |member, index|
      member.update!(
        epic: epic,
        state: "approved",
        pr_number: 100 + index,
        branch_name: "syrus/issue-#{index + 1}",
        landing_failure_reason: "landing start blocked: stack dependencies not ready"
      )
    end
    result = reconcile_and_execute(job_id: primary.id)
    issue = kind(result, :approved_job_landing_start_blocked)

    expect(issue).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "clear_landing_start_blocker_and_wake_queue"
    )
    expect(issue.evidence).to include(
      "active_repository_landing_job_id" => nil,
      "landing_failure_reason" => "landing start blocked: stack dependencies not ready"
    )
    expect(plan(result, :clear_landing_start_blocker_and_wake_queue)).to have_attributes(auto_executable: true, target_id: primary.id)
    expect(result.repair_executions.map(&:message)).to include("cleared landing-start blocker for 2 Job(s) and woke the landing queue")
    expect(blocked.map { |member| member.reload.landing_failure_reason }).to all(be_nil)
    expect(blocked.map { |member| member.reload.state }).to all(eq("approved"))
    expect(enqueued_jobs.map { |entry| entry[:job] }).to include(LandingQueueProcessorJob)
  end

  it "does not clear an Epic landing-start stack blocker while dependencies remain unresolved" do
    AppSetting.current.update!(merge_train_enabled: true)
    epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
    blocker = Factories.job_record(
      user: job.user,
      repository: job.repository,
      state: "implemented",
      issue_number: 9,
      pr_number: 109,
      branch_name: "syrus/issue-9"
    )
    primary = Factories.job_record(
      user: job.user,
      repository: job.repository,
      epic: epic,
      state: "approved",
      issue_number: 1,
      pr_number: 101,
      branch_name: "syrus/issue-1",
      landing_failure_reason: "landing start blocked: stack dependencies not ready"
    )
    JobDependency.create!(job: primary, depends_on_job: blocker, source: "manual", created_by_user: job.user)

    result = reconcile_and_execute(job_id: primary.id)
    issue = kind(result, :approved_job_landing_start_blocked)

    expect(issue).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "clear_landing_start_blocker_and_wake_queue"
    )
    expect(result.repair_executions.map(&:message)).to include("Landing-start blocker is still active")
    expect(primary.reload.landing_failure_reason).to eq("landing start blocked: stack dependencies not ready")
    expect(enqueued_jobs.map { |entry| entry[:job] }).not_to include(LandingQueueProcessorJob)
  end

  it "treats a failed Job with a newer queued retry workflow as auto-repairable state drift" do
    workflow.update_columns(
      trigger_kind: "rebase",
      state: "failed",
      started_at: 10.minutes.ago,
      finished_at: 9.minutes.ago,
      created_at: 10.minutes.ago
    )
    retry_workflow = Workflow.create!(
      job: job,
      trigger_kind: "retry",
      state: "queued",
      created_at: 1.minute.ago
    )
    job.update_columns(state: "failed")

    result = reconcile(job_id: job.id)
    issue = kind(result, :unambiguous_job_state_drift)

    expect(kind(result, :job_workflow_state_drift)).to be_nil
    expect(issue).to have_attributes(
      safe_to_auto_repair: true,
      recommended_repair_action: "reconcile_job_state"
    )
    expect(issue.affected_ids[:workflow_ids]).to eq([ retry_workflow.id ])
    expect(issue.evidence).to include(
      "job_state" => "failed",
      "target_state" => "queued",
      "latest_workflow_state" => "queued"
    )
  end

  it "classifies missing workspaces for active workflows" do
    workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_hostname: nil)
    step.update_columns(state: "running", started_at: 5.minutes.ago)
    run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 5.minutes.ago)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :workspace_missing)

    expect(issue.severity).to eq("critical")
    expect(issue.recommended_repair_action).to eq("start_over_with_fresh_workflow")
    expect(plan(result, :operator_review_missing_workspace).auto_executable).to eq(false)
  end

  it "does not report missing workspace when a live remote worker owns the workflow" do
    live_worker_queue!("resume-storage-remote", hostname: "syrus-worker-remote")
    workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_hostname: "syrus-worker-remote", worker_storage_key: "storage-remote")
    step.update_columns(state: "running", started_at: 5.minutes.ago)
    run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 5.minutes.ago)
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)

    result = reconcile(workflow_id: workflow.id)

    expect(kind(result, :workspace_missing)).to be_nil
    expect(result.snapshot.workspaces[workflow.id]).to include(
      exists: true,
      inspected: false,
      worker_hostname: "syrus-worker-remote",
      worker_storage_key: "storage-remote"
    )
  end

  it "classifies resumable agent sessions present and missing" do
    agent_step = workflow.steps.find_by!(kind: "implement")
    present = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "failed",
      agent_outcome: "worker_died",
      finished_at: Time.current
    )
    ClaudeSession.create!(resumable: present, provider: "claude", session_id: "session-1", transcript_jsonl: "{}\n")
    missing = agent_step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "failed",
      agent_outcome: "worker_died",
      live_session_id: "session-2",
      finished_at: Time.current
    )

    result = reconcile(workflow_id: workflow.id)

    present_issue = kind(result, :resumable_agent_session_present)
    missing_issue = kind(result, :resumable_agent_session_missing)
    expect(present_issue.affected_ids[:run_ids]).to include(present.id)
    expect(present_issue.safe_to_auto_repair).to eq(true)
    expect(missing_issue.affected_ids[:run_ids]).to include(missing.id)
    expect(missing_issue.safe_to_auto_repair).to eq(false)
    expect(plan(result, :resume_failed_step)).to have_attributes(auto_executable: true, target_id: present.id)
  end

  it "plans retryable rate-limit failures for the reset time instead of immediate retry" do
    reset_at = 12.minutes.from_now
    job.user.update!(gh_rate_limit_reset_at: reset_at)
    run.update_columns(state: "failed", finished_at: Time.current)
    step.update_columns(state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "rate_limited",
      retryable: true,
      confidence: 0.9,
      reason: "GitHub API rate limited",
      classified_at: Time.current
    )

    result = reconcile(run_id: run.id)
    issue = kind(result, :retryable_run_failure)
    repair_plan = result.repair_plans.find { |candidate| candidate.action == "schedule_retry_after_rate_limit" && candidate.target_id == run.id }

    expect(issue.retry_after.to_i).to eq(reset_at.to_i)
    expect(repair_plan.auto_executable).to eq(true)
    expect(repair_plan.retry_after.to_i).to eq(reset_at.to_i)
  end

  it "plans provider usage-limit failures for the provider reset time" do
    run.update_columns(
      state: "failed",
      agent_provider: "claude",
      agent_outcome: "provider_usage_limit",
      finished_at: Time.zone.parse("2026-08-01 08:30:00 UTC")
    )
    step.update_columns(state: "failed", finished_at: run.finished_at)
    workflow.update_columns(state: "failed", finished_at: run.finished_at)
    RunDiagnostic.create!(
      run: run,
      error_class: "Steps::Base::StepFailed",
      error_message: "You're out of extra usage · resets 7am (America/New_York)"
    )
    RunFailureClassification.create!(
      run: run,
      classification: "provider_usage_limit",
      retryable: false,
      confidence: 0.95,
      reason: "provider usage exhausted",
      classified_at: run.finished_at
    )

    result = reconcile(run_id: run.id, now: Time.zone.parse("2026-08-01 10:00:00 UTC"))
    issue = kind(result, :retryable_run_failure)
    repair_plan = result.repair_plans.find { |candidate| candidate.action == "schedule_retry_after_rate_limit" && candidate.target_id == run.id }

    expect(issue.retry_after).to eq(Time.find_zone("America/New_York").parse("2026-08-01 07:05:00"))
    expect(repair_plan).to have_attributes(auto_executable: true, target_id: run.id)
    expect(kind(result, :nonretryable_semantic_git_failure)).to be_nil
  end

  it "plans deterministic idempotent failed steps for in-place retry" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    result = reconcile(run_id: run.id)
    repair_plan = plan(result, :retry_failed_step)

    expect(repair_plan).to have_attributes(auto_executable: true, target_type: "Workflow", target_id: workflow.id)
    expect(repair_plan.preconditions["step_repair_semantics"]).to eq("deterministic_idempotent")
  end

  it "executes safe retry plans through AutoRetryAttempt and AutoRetryJob" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    result = nil
    expect {
      result = reconcile_and_execute(run_id: run.id)
    }.to change { AutoRetryAttempt.where(retry_kind: "failed_step").count }.by(1)
      .and have_enqueued_job(AutoRetryJob)

    attempt = AutoRetryAttempt.last
    expect(attempt).to have_attributes(workflow: workflow, run: run, failure_classification: "timeout")
    expect(result.repair_executions.map(&:message)).to include(match(/scheduled failed_step auto-retry/))
  end

  it "does not count skipped retry attempts against WorkEngine retry budget" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    3.times do |i|
      AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: run,
        agent_provider: "claude",
        failure_classification: "timeout",
        retry_kind: "failed_step",
        attempt_number: i + 1,
        scheduled_at: Time.current,
        skipped_reason: "Claude appears degraded; automatic retries are paused."
      )
    end
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    expect {
      reconcile_and_execute(run_id: run.id)
    }.to change { AutoRetryAttempt.where(retry_kind: "failed_step", skipped_reason: nil).count }.by(1)
      .and have_enqueued_job(AutoRetryJob)

    expect(AutoRetryAttempt.last.attempt_number).to eq(1)
  end

  it "executes provider quota plans by creating a delayed auto-retry attempt" do
    reset_at = Time.find_zone("America/New_York").parse("2026-08-01 07:05:00")
    run.update_columns(
      state: "failed",
      agent_provider: "claude",
      agent_outcome: "provider_usage_limit",
      finished_at: Time.zone.parse("2026-08-01 08:30:00 UTC")
    )
    step.update_columns(state: "failed", finished_at: run.finished_at)
    workflow.update_columns(state: "failed", finished_at: run.finished_at)
    RunDiagnostic.create!(
      run: run,
      error_class: "Steps::Base::StepFailed",
      error_message: "You're out of extra usage · resets 7am (America/New_York)"
    )
    RunFailureClassification.create!(
      run: run,
      classification: "provider_usage_limit",
      retryable: false,
      confidence: 0.95,
      reason: "provider usage exhausted",
      classified_at: run.finished_at
    )

    expect {
      reconcile_and_execute(run_id: run.id, now: Time.zone.parse("2026-08-01 10:00:00 UTC"))
    }.to change { AutoRetryAttempt.where(failure_classification: "provider_usage_limit").count }.by(1)
      .and have_enqueued_job(AutoRetryJob)

    attempt = AutoRetryAttempt.last
    expect(attempt).to have_attributes(workflow: workflow, run: run, retry_kind: "failed_step")
    expect(attempt.scheduled_at.to_i).to eq(reset_at.to_i)
  end

  it "does not execute safe retry plans while the provider circuit is open" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)
    decision = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider transient failures",
      retry_after: 10.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: "timeout"
    )
    allow(ProviderCircuitBreaker).to receive(:call).with("claude", now: kind_of(Time)).and_return(decision)
    allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([ decision ])

    result = nil
    expect {
      result = reconcile_and_execute(run_id: run.id)
    }.not_to change { AutoRetryAttempt.count }

    expect(plan(result, :retry_failed_step)).to have_attributes(auto_executable: true)
    expect(result.repair_executions.map(&:message)).to include(match(/provider circuit is open for claude/))
  end

  it "coalesces repeated no-op retry repair audit logs for an unchanged stuck run" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: run.agent_provider,
      failure_classification: "timeout",
      retry_kind: "failed_step",
      attempt_number: 1,
      scheduled_at: 1.minute.from_now
    )
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    3.times do
      perform_enqueued_jobs do
        described_class.request(source: "spec", run: run)
      end
    end

    audit_chunks = JobLog.where(run: run, kind: "system").pluck(:chunk)
    expect(audit_chunks.grep(/\[work-engine reconciler\] applying retry_failed_step/).size).to eq(1)
    expect(audit_chunks.grep(/\[work-engine reconciler\] skipped retry_failed_step: retry already pending/).size).to eq(1)
  end

  it "executes unambiguous Job state drift repairs" do
    run.update_columns(state: "succeeded", finished_at: Time.current)
    step.update_columns(state: "succeeded", finished_at: Time.current)
    workflow.update_columns(state: "succeeded", finished_at: Time.current)
    job.update_columns(state: "running")

    result = reconcile_and_execute(job_id: job.id)

    expect(kind(result, :unambiguous_job_state_drift)).to be_present
    expect(plan(result, :reconcile_job_state)).to have_attributes(auto_executable: true)
    expect(job.reload.state).to eq("implemented")
    expect(result.repair_executions.map(&:status)).to include("applied")
  end

  it "escalates retryable failures when the retry budget is exhausted" do
    step.update_columns(kind: "grader", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "timeout",
      retryable: true,
      confidence: 0.85,
      reason: "grader timed out",
      classified_at: Time.current
    )
    AutoRetryAttempt::MAX_ATTEMPTS.times do |index|
      AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: run,
        agent_provider: run.agent_provider,
        failure_classification: "timeout",
        retry_kind: "failed_step",
        attempt_number: index + 1,
        scheduled_at: Time.current
      )
    end
    allow(File).to receive(:directory?).and_call_original
    allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(true)

    result = reconcile(run_id: run.id)
    repair_plan = plan(result, :operator_review_retry_budget_exhausted)

    expect(repair_plan.auto_executable).to eq(false)
    expect(repair_plan.preconditions["retry_budget_available"]).to eq(false)
  end

  it "classifies nonretryable semantic and git failures" do
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "git_conflict",
      retryable: false,
      confidence: 0.9,
      reason: "manual conflict resolution required",
      classified_at: Time.current
    )

    result = reconcile(run_id: run.id)
    issue = kind(result, :nonretryable_semantic_git_failure)

    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.evidence["classification"]).to eq("git_conflict")
    expect(plan(result, :operator_review_nonretryable_failure).auto_executable).to eq(false)
  end

  it "escalates non-idempotent publication step failures" do
    step.update_columns(kind: "pr_open", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "git_non_fast_forward",
      retryable: false,
      confidence: 0.95,
      reason: "branch changed before push",
      classified_at: Time.current
    )

    result = reconcile(run_id: run.id)
    repair_plan = plan(result, :operator_review_nonretryable_failure)

    expect(repair_plan.auto_executable).to eq(false)
    expect(repair_plan.preconditions["step_repair_semantics"]).to eq("publication")
  end

  it "does not escalate stale pr_open divergence after a newer workflow published the same branch" do
    job.update!(pr_number: 77, branch_name: "syrus/direct-#{job.id}")
    step.update_columns(kind: "pr_open", state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current)
    run.update_columns(state: "failed", finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: "git_non_fast_forward",
      retryable: false,
      confidence: 0.95,
      reason: "branch changed before push",
      classified_at: Time.current
    )
    newer = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: workflow.agent_provider)
    newer.update!(state: "succeeded", artifacts: { "publication_branch" => job.branch_name })

    result = reconcile(run_id: run.id)

    expect(kind(result, :nonretryable_semantic_git_failure)).to be_nil
    expect(plan(result, :operator_review_nonretryable_failure)).to be_nil
  end

  it "classifies provider rate limits from the circuit breaker" do
    decision = ProviderCircuitBreaker::Decision.new(
      provider: "claude",
      open: true,
      reason: "provider transient failures",
      retry_after: 10.minutes.from_now,
      failure_count: 5,
      job_count: 3,
      signature: "429",
      usage_limit: false
    )
    allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([ decision ])

    result = reconcile(job_id: job.id)
    issue = kind(result, :rate_limit)

    expect(issue.severity).to eq("warning")
    expect(issue.retry_after).to eq(decision.retry_after)
    expect(issue.recommended_repair_action).to eq("wait_for_provider_recovery")
    expect(plan(result, :schedule_retry_after_rate_limit)).to have_attributes(
      auto_executable: false,
      retry_after: decision.retry_after
    )
  end
end

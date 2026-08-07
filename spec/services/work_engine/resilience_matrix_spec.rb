require "rails_helper"

RSpec.describe "Work engine resilience regression matrix" do
  include ActiveJob::TestHelper

  around do |example|
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
    clear_enqueued_jobs
    clear_performed_jobs
  end

  before do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
    allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([])
    allow(InstanceVersion).to receive(:worst_data_root).and_return(nil)
    allow(File).to receive(:directory?).and_return(true)
  end

  after do
    clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
  end

  def reconcile(target)
    WorkEngine::Reconciler.call(source: "resilience_matrix_spec", **target)
  end

  def issue(result, kind)
    result.issues.find { |candidate| candidate.kind == kind.to_s }
  end

  def plan(result, action)
    result.repair_plans.find { |candidate| candidate.action == action.to_s }
  end

  def matrix_job
    Factories.job(agent_provider: "claude")
  end

  def matrix_graph
    job = matrix_job
    workflow = job.latest_workflow
    step = workflow.first_step
    run = step.runs.first
    [ job, workflow, step, run ]
  end

  def age_active_run!(workflow, step, run, heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
    workflow.update_columns(state: "running", started_at: heartbeat_age.ago)
    step.update_columns(state: "running", started_at: heartbeat_age.ago)
    run.update_columns(state: "running", started_at: heartbeat_age.ago, last_heartbeat_at: heartbeat_age.ago)
  end

  def queued_run!(workflow, step, run, age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 1.minute)
    workflow.update_columns(state: "running", started_at: age.ago)
    step.update_columns(state: "queued", created_at: age.ago, updated_at: age.ago)
    run.update_columns(state: "queued", created_at: age.ago, updated_at: age.ago)
  end

  def fail_run!(workflow, step, run, classification:, retryable:, step_kind: "grader", agent_outcome: nil)
    step.update_columns(kind: step_kind, state: "failed", finished_at: Time.current)
    workflow.update_columns(state: "failed", finished_at: Time.current, cleaned_up_at: nil)
    run.update_columns(state: "failed", agent_outcome: agent_outcome, finished_at: Time.current)
    RunFailureClassification.create!(
      run: run,
      classification: classification,
      retryable: retryable,
      confidence: 0.9,
      reason: "#{classification} matrix case",
      classified_at: Time.current
    )
  end

  def solid_queue_run_job(run, claimed: false, failed: false, process_heartbeat: 20.minutes.ago)
    ensure_solid_queue_test_tables!
    queue_job = SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: "runs",
      priority: 10,
      arguments: { "arguments" => [ run.id ] },
      created_at: 15.minutes.ago,
      updated_at: 15.minutes.ago
    )
    if claimed
      process = SolidQueue::Process.create!(
        hostname: "worker-1",
        kind: "worker",
        last_heartbeat_at: process_heartbeat,
        metadata: {},
        name: "worker-1:1",
        pid: 123,
        created_at: 15.minutes.ago
      )
      SolidQueue::ClaimedExecution.create!(job: queue_job, process_id: process.id, created_at: 15.minutes.ago)
    end
    SolidQueue::FailedExecution.create!(job: queue_job, error: "worker process pruned", created_at: 1.minute.ago) if failed
    queue_job
  end

  def expect_matrix_row(label:, target:, issue_kind:, action:, auto_executable:)
    result = reconcile(target)
    found_issue = issue(result, issue_kind)
    found_plan = plan(result, action)

    expect(found_issue).to be_present, "#{label} did not emit #{issue_kind}; got #{result.issue_kinds.inspect}"
    expect(found_plan).to be_present, "#{label} did not plan #{action}; got #{result.repair_plans.map(&:action).inspect}"
    expect(found_plan.auto_executable).to eq(auto_executable), "#{label} automation posture changed"
    expect(found_plan.issue_kind).to eq(issue_kind.to_s)
  end

  matrix = {
    "JOB-2260 stale queued retry Run" => {
      issue_kind: :queued_run_without_queue_claim,
      action: :reenqueue_run,
      auto_executable: true,
      setup: lambda {
        job, workflow, step, original_run = matrix_graph
        original_run.update_columns(state: "failed", finished_at: 6.minutes.ago)
        retry_run = step.runs.create!(
          job: job,
          user: job.user,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider,
          state: "queued",
          created_at: 5.minutes.ago,
          updated_at: 5.minutes.ago
        )
        ensure_solid_queue_test_tables!
        clear_solid_queue_test_tables!
        workflow.update_columns(state: "running", started_at: 6.minutes.ago)
        step.update_columns(state: "queued")
        { workflow_id: retry_run.workflow_id }
      }
    },
    "worker process pruned" => {
      issue_kind: :running_run_without_live_worker_evidence,
      action: :mark_worker_died_and_retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        age_active_run!(workflow, step, run)
        SpawnedProcess.create!(
          run: run,
          workflow: workflow,
          kind: "agent",
          command: "codex exec",
          hostname: "worker-1",
          started_at: 45.minutes.ago,
          finished_at: 35.minutes.ago,
          outcome: "orphaned"
        )
        { run_id: run.id }
      }
    },
    "worker crash after creating inline successor" => {
      issue_kind: :queued_run_without_queue_claim,
      action: :reenqueue_run,
      auto_executable: true,
      setup: lambda {
        job, workflow, step, root_run = matrix_graph
        root_run.update_columns(state: "succeeded", finished_at: 6.minutes.ago)
        successor = step.runs.create!(
          job: job,
          user: job.user,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider,
          state: "queued",
          created_at: 5.minutes.ago,
          updated_at: 5.minutes.ago
        )
        ensure_solid_queue_test_tables!
        clear_solid_queue_test_tables!
        workflow.update_columns(state: "running", started_at: 6.minutes.ago)
        { run_id: successor.id }
      }
    },
    "stale heartbeat" => {
      issue_kind: :running_run_without_live_worker_evidence,
      action: :mark_worker_died_and_retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        age_active_run!(workflow, step, run)
        { run_id: run.id }
      }
    },
    "SolidQueue failed execution" => {
      issue_kind: :queued_run_solid_queue_failed_execution,
      action: :reenqueue_run,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        queued_run!(workflow, step, run)
        solid_queue_run_job(run, failed: true)
        { run_id: run.id }
      }
    },
    "SolidQueue stale active claim" => {
      issue_kind: :queued_run_stale_queue_claim,
      action: :diagnose_queue_starvation,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        queued_run!(workflow, step, run)
        solid_queue_run_job(run, claimed: true, process_heartbeat: 20.minutes.ago)
        { run_id: run.id }
      }
    },
    "queue/resource congestion" => {
      issue_kind: :resource_congestion,
      action: :wait_for_capacity,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        queued_run!(workflow, step, run)
        other_job = matrix_job
        other_workflow = other_job.latest_workflow
        other_step = other_workflow.first_step
        other_run = other_step.runs.first
        age_active_run!(other_workflow, other_step, other_run, heartbeat_age: 1.minute)
        allow(AppSetting).to receive(:max_concurrent_agent_runs).and_return(1)
        { run_id: run.id }
      }
    },
    "runs paused" => {
      issue_kind: :runs_paused,
      action: :wait_for_queue_resume,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        queued_run!(workflow, step, run)
        solid_queue_run_job(run)
        SolidQueue::Pause.create!(queue_name: "runs", created_at: 2.minutes.ago)
        { run_id: run.id }
      }
    },
    "provider timeout" => {
      issue_kind: :retryable_run_failure,
      action: :retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "timeout", retryable: true)
        { run_id: run.id }
      }
    },
    "provider rate limit" => {
      issue_kind: :rate_limit,
      action: :schedule_retry_after_rate_limit,
      auto_executable: false,
      setup: lambda {
        decision = ProviderCircuitBreaker::Decision.new(
          provider: "claude",
          open: true,
          reason: "provider 429",
          retry_after: 10.minutes.from_now,
          failure_count: 3,
          job_count: 2,
          signature: "429",
          usage_limit: false
        )
        allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([ decision ])
        job = matrix_job
        { job_id: job.id }
      }
    },
    "provider usage limit" => {
      issue_kind: :rate_limit,
      action: :schedule_retry_after_rate_limit,
      auto_executable: false,
      setup: lambda {
        decision = ProviderCircuitBreaker::Decision.new(
          provider: "claude",
          open: true,
          reason: "usage limit",
          retry_after: 24.hours.from_now,
          failure_count: 1,
          job_count: 1,
          signature: "usage",
          usage_limit: true
        )
        allow(ProviderCircuitBreaker).to receive(:open_circuits).and_return([ decision ])
        job = matrix_job
        { job_id: job.id }
      }
    },
    "GitHub rate limit" => {
      issue_kind: :retryable_run_failure,
      action: :schedule_retry_after_rate_limit,
      auto_executable: true,
      setup: lambda {
        job, workflow, step, run = matrix_graph
        job.user.update!(gh_rate_limit_reset_at: 12.minutes.from_now)
        fail_run!(workflow, step, run, classification: "rate_limited", retryable: true)
        { run_id: run.id }
      }
    },
    "MCP sidecar failure" => {
      issue_kind: :retryable_run_failure,
      action: :retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "mcp_sidecar_failure", retryable: true)
        { run_id: run.id }
      }
    },
    "database lock" => {
      issue_kind: :retryable_run_failure,
      action: :retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "database_lock", retryable: true)
        { run_id: run.id }
      }
    },
    "workspace missing" => {
      issue_kind: :workspace_missing,
      action: :operator_review_missing_workspace,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        age_active_run!(workflow, step, run, heartbeat_age: 5.minutes)
        allow(File).to receive(:directory?).and_return(false)
        { workflow_id: workflow.id }
      }
    },
    "resumable agent session present" => {
      issue_kind: :resumable_agent_session_present,
      action: :resume_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "worker_died", retryable: true, step_kind: "implement", agent_outcome: "worker_died")
        ClaudeSession.create!(resumable: run, provider: "claude", session_id: "session-1", transcript_jsonl: "{}\n")
        { run_id: run.id }
      }
    },
    "nonresumable agent failure" => {
      issue_kind: :resumable_agent_session_missing,
      action: :retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "worker_died", retryable: true, step_kind: "implement", agent_outcome: "worker_died")
        { run_id: run.id }
      }
    },
    "deterministic step failure" => {
      issue_kind: :retryable_run_failure,
      action: :retry_failed_step,
      auto_executable: true,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "transient_process_failure", retryable: true, step_kind: "prepare")
        { run_id: run.id }
      }
    },
    "grader loop continuation/exhaustion" => {
      issue_kind: :retryable_run_failure,
      action: :operator_review_retry_budget_exhausted,
      auto_executable: false,
      setup: lambda {
        job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "timeout", retryable: true, step_kind: "grader")
        AutoRetryScheduler::MAX_ATTEMPTS.times do |index|
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
        { run_id: run.id }
      }
    },
    "main branch broken" => {
      issue_kind: :main_branch_broken,
      action: :wait_for_main_recovery,
      auto_executable: false,
      setup: lambda {
        job, workflow, step, run = matrix_graph
        job.repository.update!(ci_health: "broken", landing_paused: true)
        fail_run!(workflow, step, run, classification: "timeout", retryable: true)
        workflow.update!(artifacts: { "main_broken" => true })
        { workflow_id: workflow.id }
      }
    },
    "dependency/stack blocked" => {
      issue_kind: :dependency_stack_start_block,
      action: :wait_for_dependency_or_stack_readiness,
      auto_executable: false,
      setup: lambda {
        job, workflow, _step, run = matrix_graph
        prerequisite = Factories.job(repository: job.repository, issue_number: 99)
        JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
        run.destroy!
        workflow.update_columns(
          state: "queued",
          artifacts: {
            "start_blocked_reason" => StepDispatcher::STACK_BLOCK_REASON,
            "start_blocked_next_check_at" => 5.minutes.from_now.iso8601
          }
        )
        { workflow_id: workflow.id }
      }
    },
    "rebase cap" => {
      issue_kind: :nonretryable_semantic_git_failure,
      action: :operator_review_nonretryable_failure,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        workflow.update_columns(trigger_kind: "auto_merge")
        fail_run!(workflow, step, run, classification: "rebase_cap_reached", retryable: false, step_kind: "auto_merge")
        { run_id: run.id }
      }
    },
    "branch divergence" => {
      issue_kind: :nonretryable_semantic_git_failure,
      action: :operator_review_nonretryable_failure,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "branch_diverged", retryable: false, step_kind: "pr_open")
        { run_id: run.id }
      }
    },
    "empty commit/no_changes" => {
      issue_kind: :nonretryable_semantic_git_failure,
      action: :operator_review_nonretryable_failure,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        fail_run!(workflow, step, run, classification: "empty_commit", retryable: false, step_kind: "pr_open")
        { run_id: run.id }
      }
    },
    "Job/Workflow state drift" => {
      issue_kind: :job_workflow_state_drift,
      action: :operator_review_state_transition,
      auto_executable: false,
      setup: lambda {
        job, workflow, _step, _run = matrix_graph
        workflow.update_columns(state: "running", started_at: 5.minutes.ago)
        job.update_columns(state: "failed")
        { job_id: job.id }
      }
    },
    "active descendants preventing cleanup" => {
      issue_kind: :cleanup_blocked_by_active_descendants,
      action: :operator_review_active_descendants,
      auto_executable: false,
      setup: lambda {
        _job, workflow, step, run = matrix_graph
        workflow.update_columns(state: "succeeded", finished_at: 10.minutes.ago, cleaned_up_at: nil)
        step.update_columns(state: "running", started_at: 11.minutes.ago)
        run.update_columns(state: "running", started_at: 11.minutes.ago, last_heartbeat_at: 1.minute.ago)
        { workflow_id: workflow.id }
      }
    },
    "closed Job with active workflow/run" => {
      issue_kind: :closed_job_active_workflow,
      action: :cancel_workflow_for_closed_job,
      auto_executable: true,
      setup: lambda {
        job, workflow, step, run = matrix_graph
        workflow.update_columns(state: "running", started_at: 5.minutes.ago)
        step.update_columns(state: "running", started_at: 5.minutes.ago)
        run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 1.minute.ago)
        job.update_columns(state: "closed", finished_at: 2.minutes.ago, closure_reason: "operator_cancelled")
        { job_id: job.id }
      }
    }
  }

  matrix.each do |label, row|
    it "covers #{label}" do
      target = instance_exec(&row.fetch(:setup))

      expect_matrix_row(
        label: label,
        target: target,
        issue_kind: row.fetch(:issue_kind),
        action: row.fetch(:action),
        auto_executable: row.fetch(:auto_executable)
      )
    end
  end

  it "always delegates disconnected fixers to the unified reconciler" do
    _job, workflow, _step, run = matrix_graph
    fail_run!(workflow, workflow.first_step, run, classification: "worker_died", retryable: true, agent_outcome: "worker_died")

    expect {
      AutoRetryScheduler.schedule_for_workflow(workflow: workflow)
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "AutoRetryScheduler",
      job_id: workflow.job_id,
      workflow_id: workflow.id,
      run_id: nil
    )
    expect(AutoRetryAttempt.count).to eq(0)
  end
end

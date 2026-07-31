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

  def kind(result, name)
    result.issues.find { |issue| issue.kind == name.to_s }
  end

  def solid_queue_run_job(run, claimed: false, process_id: nil, created_at: 10.minutes.ago)
    ensure_solid_queue_test_tables!
    queue_job = SolidQueue::Job.create!(
      class_name: "RunJob",
      queue_name: "runs",
      priority: 10,
      arguments: { "arguments" => [ run.id ] },
      created_at: created_at,
      updated_at: created_at
    )
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
    queue_job
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
  end

  it "classifies a queued Run with a stale SolidQueue claim" do
    solid_queue_run_job(run, claimed: true, created_at: 15.minutes.ago)
    run.update_columns(state: "queued", created_at: 15.minutes.ago, updated_at: 15.minutes.ago)

    result = reconcile(run_id: run.id)
    issue = kind(result, :queued_run_stale_queue_claim)

    expect(issue.severity).to eq("warning")
    expect(issue.safe_to_auto_repair).to eq(false)
    expect(issue.recommended_repair_action).to eq("check_queue_worker_or_wait")
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

    result = reconcile(run_id: run.id)
    issue = kind(result, :running_run_without_live_worker_evidence)

    expect(issue.severity).to eq("critical")
    expect(issue.safe_to_auto_repair).to eq(true)
    expect(issue.recommended_repair_action).to eq("fail_run_as_worker_died")
  end

  it "classifies a queued Workflow without a first Run" do
    run.destroy!
    workflow.update_columns(state: "queued", created_at: 5.minutes.ago, updated_at: 5.minutes.ago)
    step.update_columns(state: "queued")

    result = reconcile(workflow_id: workflow.id)
    issue = kind(result, :queued_workflow_without_first_run)

    expect(issue.safe_to_auto_repair).to eq(true)
    expect(issue.recommended_repair_action).to eq("start_workflow")
  end

  it "classifies explicit dependency or stack start blocks as wait-only" do
    run.destroy!
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
    expect(issue.check_after).to be_present
  end

  it "classifies Job/Workflow state drift" do
    workflow.update_columns(state: "running", started_at: 5.minutes.ago)
    job.update_columns(state: "failed")

    result = reconcile(job_id: job.id)
    issue = kind(result, :job_workflow_state_drift)

    expect(issue.recommended_repair_action).to eq("operator_review_state_transition")
    expect(issue.affected_ids[:workflow_ids]).to include(workflow.id)
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
  end
end

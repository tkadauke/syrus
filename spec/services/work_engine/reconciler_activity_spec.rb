require "rails_helper"

RSpec.describe WorkEngine::ReconcilerActivity do
  def reconciler_result(job:, workflow:, run:, execution_status: "applied")
    issue = WorkEngine::Reconciler::Issue.new(
      kind: "queued_run_without_queue_claim",
      severity: "error",
      evidence: { solid_queue_state: "missing" },
      affected_ids: { job_ids: [ job.id ], workflow_ids: [ workflow.id ], run_ids: [ run.id ] },
      safe_to_auto_repair: true,
      recommended_repair_action: "reenqueue_run",
      explanation: "Run is queued but no active SolidQueue RunJob references it."
    )
    snapshot = instance_double(WorkEngine::Reconciler::Snapshot, as_json: {})
    WorkEngine::Reconciler::Result.new(
      "spec",
      Time.current,
      snapshot,
      [ issue ],
      [
        WorkEngine::RepairPlanner::Plan.new(
          issue_kind: issue.kind,
          action: "reenqueue_run",
          auto_executable: true,
          target_type: "Run",
          target_id: run.id,
          affected_ids: issue.affected_ids,
          execution_steps: [ "Run#reenqueue!" ],
          preconditions: {},
          reason: "The queued Run has no queue claim."
        )
      ],
      [
        WorkEngine::RepairExecutor::Execution.new(
          action: "reenqueue_run",
          target_type: "Run",
          target_id: run.id,
          status: execution_status,
          message: execution_status == "skipped" ? "retry already pending" : "re-enqueued #{run.slug}"
        )
      ]
    )
  end

  it "records actionable issues, plans, executions, and a summary for a repairing reconciler result" do
    job = Factories.job
    workflow = job.workflows.first
    run = job.initial_run
    result = reconciler_result(job: job, workflow: workflow, run: run)

    described_class.record_result!(
      source: "spec",
      job_id: job.id,
      execute_repairs: true,
      result: result
    )

    expect(WorkEngineReconcilerActivityEvent.order(:id).pluck(:event_type)).to eq(
      %w[issues_detected repair_planned repair_executed run_finished]
    )
    expect(WorkEngineReconcilerActivityEvent.find_by!(event_type: "issues_detected")).to have_attributes(
      job_id: job.id,
      workflow_id: workflow.id,
      run_id: run.id,
      issue_kind: "queued_run_without_queue_claim",
      repair_action: "reenqueue_run"
    )
    expect(WorkEngineReconcilerActivityEvent.find_by!(event_type: "run_finished").details).to include(
      "issues_count" => 1,
      "repair_executions_count" => 1
    )
  end

  it "records skipped auto-safe repairs as operator-visible attention events" do
    job = Factories.job
    result = reconciler_result(
      job: job,
      workflow: job.workflows.first,
      run: job.initial_run,
      execution_status: "skipped"
    )

    described_class.record_result!(
      source: "spec",
      execute_repairs: true,
      result: result
    )

    expect(WorkEngineReconcilerActivityEvent.order(:id).pluck(:event_type)).to eq(
      %w[issues_detected repair_planned repair_executed run_finished]
    )
    expect(WorkEngineReconcilerActivityEvent.find_by!(event_type: "repair_executed")).to have_attributes(
      severity: "warn",
      repair_status: "skipped",
      message: "retry already pending"
    )
  end

  it "does not record skipped operator-only repair passes as activity" do
    job = Factories.job
    result = reconciler_result(
      job: job,
      workflow: job.workflows.first,
      run: job.initial_run,
      execution_status: "skipped"
    )
    issue = result.issues.first.with(safe_to_auto_repair: false)
    repair_plan = result.repair_plans.first.with(auto_executable: false)
    result = result.with(issues: [ issue ], repair_plans: [ repair_plan ])

    described_class.record_result!(
      source: "spec",
      execute_repairs: true,
      result: result
    )

    expect(WorkEngineReconcilerActivityEvent.count).to eq(0)
  end

  it "does not record read-only reconciler inspections as activity" do
    job = Factories.job
    result = reconciler_result(job: job, workflow: job.workflows.first, run: job.initial_run)

    described_class.record_run_started!(source: "spec", execute_repairs: false)
    described_class.record_result!(source: "spec", execute_repairs: false, result: result)

    expect(WorkEngineReconcilerActivityEvent.count).to eq(0)
  end
end

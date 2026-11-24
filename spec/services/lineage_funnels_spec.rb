require "rails_helper"

# NY40: the transaction funnels that write up the tree take their ancestry
# with Lineage.lock! first, so they stay in the hierarchical row-lock order
# (parents before children) with writes counted. Each example runs one funnel
# with the checker raising on the hierarchical order.
RSpec.describe "Lineage funnels" do
  let(:job) { Factories.job }
  let(:workflow) { job.reload.workflows.order(:id).last }
  let(:step) { workflow.steps.order(:position).first }

  around do |example|
    previous_target = Syrus::LockOrder.target
    previous_mode = Syrus::LockOrder::Checker.mode
    previous_writes = ENV["SYRUS_LOCK_ORDER_WRITES"]
    Syrus::LockOrder.target = :hierarchical
    ENV["SYRUS_LOCK_ORDER_WRITES"] = "1"
    example.run
  ensure
    Syrus::LockOrder.target = previous_target
    Syrus::LockOrder::Checker.mode = previous_mode
    ENV["SYRUS_LOCK_ORDER_WRITES"] = previous_writes
  end

  # Builds the rows outside the checked region: rows a transaction inserts
  # itself are outside the order.
  def running_step_with_run
    workflow.update_columns(state: "running", started_at: Time.current)
    step.update_columns(state: "running", started_at: Time.current)
    Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, state: "running", started_at: Time.current)
  end

  def checked
    Syrus::LockOrder::Checker.mode = :raise
    yield
  ensure
    Syrus::LockOrder::Checker.mode = :record
  end

  it "cancels a running Workflow with an active Step and Run in order" do
    run = running_step_with_run

    checked { WorkUnits::WorkflowCancellation.cancel!(workflow.reload, reason: "operator_cancelled") }

    expect(workflow.reload).to be_cancelled
    expect(run.reload).to be_cancelled
  end

  it "retires a WorkUnit and settles its intent in order" do
    unit = workflow.work_unit

    workflow.update_columns(state: "succeeded", finished_at: Time.current)
    checked { unit.mark_terminal!("succeeded") }

    expect(unit.reload.state).to eq("succeeded")
    expect(unit.work_intent.reload.state).to eq("satisfied")
  end

  it "preempts an active WorkUnit in order" do
    unit = workflow.work_unit

    checked { WorkUnit.transaction { unit.preempt!(reason: "spec") } }

    expect(unit.reload.preemption_reason).to eq("spec")
  end

  it "cancels a Workflow whose WorkUnit was cancelled elsewhere in order" do
    running_step_with_run
    workflow.work_unit.update_columns(state: "cancelled", finished_at: Time.current)

    checked { WorkUnits::TerminalWorkflowSync.call(workflow.reload) }

    expect(workflow.reload).to be_cancelled
  end

  it "creates a Step's Run in order" do
    workflow.update_columns(state: "running", started_at: Time.current)
    step.runs.update_all(state: "cancelled", finished_at: Time.current)

    run = checked { StepDispatcher.create_run_and_enqueue(step.reload, workflow.reload) }

    expect(run).to be_persisted
  end

  it "closes a Job in an Epic in order" do
    epic = Epic.create!(repository: job.repository, title: "Lineage", user: job.user)
    job.update_columns(epic_id: epic.id)

    checked { job.reload.close_with_reason!("pr_merged") }

    expect(job.reload).to be_closed
  end

  it "cancels a closed Job's active Workflow from the reconciler in order" do
    running_step_with_run
    job.update_columns(state: "closed", finished_at: 2.minutes.ago, closure_reason: "operator_cancelled")
    result = WorkEngine::Reconciler.call(source: "lineage_funnels_spec", job_id: job.id)

    executions = checked { WorkEngine::RepairExecutor.call(result: result) }

    expect(executions).to include(have_attributes(action: "cancel_workflow_for_closed_job", status: "applied"))
    expect(workflow.reload).to be_cancelled
  end
end

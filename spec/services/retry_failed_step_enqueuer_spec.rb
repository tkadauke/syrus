require "rails_helper"

RSpec.describe RetryFailedStepEnqueuer do
  def grade_retry_chain_template(repair: [ "implement" ], repair_first: false)
    [
      {
        "type" => "retry_until",
        "max_iterations" => 2,
        "repair" => repair,
        "check" => [ "grader_fanout", "grader_collect" ],
        "repair_first" => repair_first
      }
    ]
  end

  it "retries the latest failed step instead of an obsolete earlier failure" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    old_failure = Step.create!(workflow: workflow, kind: "grader_collect", position: 7)
    later_success = Step.create!(workflow: workflow, kind: "summarize", position: 22)
    terminal_failure = Step.create!(workflow: workflow, kind: "pr_open", position: 23)
    old_failure.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)
    later_success.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    terminal_failure.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to eq(terminal_failure)
    expect(terminal_failure.reload).to be_queued
    expect(terminal_failure.runs.last).to eq(result.run)
    expect(old_failure.reload).to be_failed
    expect(old_failure.runs).to be_empty
  end

  it "does not retry a tail step in place across a failed retry-until barrier" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 10,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop"
    )
    failed_tail = Step.create!(workflow: workflow, kind: "test_plan", position: 12, state: "failed")
    barrier.update!(next_step: failed_tail)

    expect(described_class.failed_step_for(workflow)).to be_nil

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_success
    expect(result.error).to eq("No failed step to retry.")
    expect(failed_tail.reload).to be_failed
    expect(failed_tail.runs).to be_empty
  end

  it "retries the whole grade loop from fanout when collect fails" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template)
    workflow.update_columns(
      state: "failed",
      started_at: 10.minutes.ago,
      finished_at: 1.minute.ago,
      failure_reason: "loop_exhausted_after_grader_failure",
      artifacts: { "failure_reason" => "loop_exhausted_after_grader_failure" }
    )

    fanout = Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 4,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop"
    )
    failed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 5,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "migration-lint", "required" => true }
    )
    collect = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 6,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop"
    )
    fanout.update!(next_step: failed_grader)
    failed_grader.update!(next_step: collect)
    fanout.runs.create!(job: job, trigger_kind: "retry", state: "succeeded")
    failed_grader.runs.create!(job: job, trigger_kind: "retry", state: "failed")
    collect.runs.create!(job: job, trigger_kind: "retry", state: "failed")

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    new_fanout = result.step
    new_collect = new_fanout.next_step

    expect(new_fanout).to have_attributes(kind: "grader_fanout", iteration: 1)
    expect(new_fanout.loop_id).not_to eq(fanout.loop_id)
    expect(new_collect).to have_attributes(kind: "grader_collect", iteration: 1)
    expect(fanout.reload).to be_succeeded
    expect(failed_grader.reload).to be_failed
    expect(collect.reload).to be_failed
    expect(collect).to be_retry_until_barrier_superseded
    expect(result.run.step).to eq(new_fanout)
    expect(workflow.reload.failure_reason).to be_nil
    expect(workflow.artifact("failure_reason")).to be_nil

    new_collect.update!(state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    expect(workflow.reload).not_to be_uncleared_retry_until_barrier
  end

  it "recovers an automatically failed fanout inside the current grade-loop iteration" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    fanout = Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 4,
      state: "failed",
      iteration: 2,
      loop_id: "grade-loop"
    )
    grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 5,
      state: "cancelled",
      iteration: 2,
      loop_id: "grade-loop",
      cancellation_reason: "cancel_terminal_workflow_active_descendants",
      details: { "name" => "tests", "required" => true }
    )
    collect = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 6,
      state: "cancelled",
      iteration: 2,
      loop_id: "grade-loop",
      cancellation_reason: "cancel_terminal_workflow_active_descendants"
    )
    summarize = Step.create!(workflow: workflow, kind: "summarize", position: 7, state: "cancelled")
    fanout.update!(next_step: collect)
    grader.update!(next_step: collect, depends_on_ids: [ fanout.id ])
    collect.update!(next_step: summarize, depends_on_ids: [ grader.id ])
    fanout.runs.create!(job: job, trigger_kind: "initial", state: "failed")

    result = described_class.call(workflow: workflow, restart_grade_loop: false)

    expect(result).to be_success
    expect(result.step).to eq(fanout)
    expect(fanout.reload).to have_attributes(state: "queued", iteration: 2, loop_id: "grade-loop")
    expect(grader.reload).to be_queued
    expect(collect.reload).to be_queued
    expect(summarize.reload).to be_queued
    expect(workflow.steps.where(kind: "grader_fanout").count).to eq(1)
    expect(workflow.artifact("manual_grade_loop_restarts")).to be_nil
  end

  it "restarts a cancelled grade loop before retrying a downstream failure" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 4, state: "succeeded", iteration: 1, loop_id: "grade-loop")
    passed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 5,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "tests", "required" => true }
    )
    cancelled_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 6,
      state: "cancelled",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "lint", "required" => true }
    )
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 7, state: "succeeded", iteration: 1, loop_id: "grade-loop")
    downstream = Step.create!(workflow: workflow, kind: "coverage_analyze", position: 8, state: "failed")
    fanout.update!(next_step: passed_grader)
    passed_grader.update!(next_step: collect, depends_on_ids: [ fanout.id ])
    cancelled_grader.update!(next_step: collect, depends_on_ids: [ fanout.id ])
    collect.update!(next_step: downstream, depends_on_ids: [ passed_grader.id, cancelled_grader.id ])
    fanout.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    passed_grader.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    collect.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    downstream.runs.create!(job: job, trigger_kind: "initial", state: "failed")

    expect(described_class.failed_step_for(workflow)).to eq(fanout)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to have_attributes(kind: "grader_fanout", iteration: 1, state: "queued")
    expect(result.step.loop_id).not_to eq("grade-loop")
    expect(downstream.reload).to be_failed
  end

  it "ignores cancelled graders from an earlier iteration when the latest iteration completed" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    old_fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 4, state: "succeeded", iteration: 1, loop_id: "grade-loop")
    Step.create!(workflow: workflow, kind: "grader", position: 5, state: "cancelled", iteration: 1, loop_id: "grade-loop", details: { "required" => true })
    Step.create!(workflow: workflow, kind: "grader_collect", position: 6, state: "failed", iteration: 1, loop_id: "grade-loop")
    new_fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 7, state: "succeeded", iteration: 2, loop_id: "grade-loop")
    Step.create!(workflow: workflow, kind: "grader", position: 8, state: "succeeded", iteration: 2, loop_id: "grade-loop", details: { "required" => true })
    Step.create!(workflow: workflow, kind: "grader_collect", position: 9, state: "succeeded", iteration: 2, loop_id: "grade-loop")
    downstream = Step.create!(workflow: workflow, kind: "coverage_analyze", position: 10, state: "failed")
    old_fanout.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    new_fanout.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    downstream.runs.create!(job: job, trigger_kind: "initial", state: "failed")

    expect(described_class.failed_step_for(workflow)).to eq(downstream)
  end

  it "appends a restarted grade loop after every prior grade-loop attempt" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    failed_fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 4, state: "succeeded", iteration: 1, loop_id: "failed-loop")
    failed_collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 5, state: "failed", iteration: 1, loop_id: "failed-loop")
    prior_restart_fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 6, state: "succeeded", iteration: 1, loop_id: "prior-restart")
    prior_restart_collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 7, state: "succeeded", iteration: 1, loop_id: "prior-restart")
    summarize = Step.create!(workflow: workflow, kind: "summarize", position: 8, state: "cancelled")
    failed_fanout.update!(next_step: failed_collect)
    failed_collect.update!(next_step: prior_restart_fanout)
    prior_restart_fanout.update!(next_step: prior_restart_collect)
    prior_restart_collect.update!(next_step: summarize)
    failed_fanout.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    failed_collect.runs.create!(job: job, trigger_kind: "initial", state: "failed")
    prior_restart_fanout.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")
    prior_restart_collect.runs.create!(job: job, trigger_kind: "initial", state: "succeeded")

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(workflow.steps.reorder(:position, :id).pluck(:loop_id, :kind)).to eq([
      [ "failed-loop", "grader_fanout" ],
      [ "failed-loop", "grader_collect" ],
      [ "prior-restart", "grader_fanout" ],
      [ "prior-restart", "grader_collect" ],
      [ result.step.loop_id, "grader_fanout" ],
      [ result.step.loop_id, "grader_collect" ],
      [ nil, "summarize" ]
    ])
    expect(prior_restart_collect.reload.next_step).to eq(result.step)
    expect(result.step.next_step.next_step).to eq(summarize)
  end

  it "resets every grader in the batch under distributed-projection wiring" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    fanout = Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 4,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop"
    )
    first_failed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 5,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "migration-lint", "required" => true }
    )
    passing_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 6,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "feature-slugs", "required" => true }
    )
    second_failed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 7,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "frontend-lint", "required" => true }
    )
    collect = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 8,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop"
    )
    fanout.update!(next_step: first_failed_grader)
    first_failed_grader.update!(next_step: collect)
    passing_grader.update!(next_step: collect)
    second_failed_grader.update!(next_step: collect)
    [ fanout, first_failed_grader, passing_grader, second_failed_grader, collect ].each do |step|
      step.runs.create!(job: job, trigger_kind: "retry", state: step.succeeded? ? "succeeded" : "failed")
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    new_fanout = result.step
    new_collect = new_fanout.next_step

    expect(new_fanout).to have_attributes(kind: "grader_fanout", iteration: 1)
    expect(new_fanout.loop_id).not_to eq(fanout.loop_id)
    expect(new_collect).to have_attributes(kind: "grader_collect", iteration: 1)
    expect(fanout.reload).to be_succeeded
    expect(first_failed_grader.reload).to be_failed
    expect(second_failed_grader.reload).to be_failed
    expect(passing_grader.reload).to be_succeeded
    expect(collect.reload).to be_failed
    expect(collect).to be_retry_until_barrier_superseded
    expect(result.run.step).to eq(new_fanout)
  end

  it "resets every grader under the default legacy serial-chain wiring" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    # GraderFanout's default (non-distributed) wiring chains graders serially
    # -- g1.next_step = g2, g2.next_step = g3, and only the LAST grader's
    # next_step is grader_collect. failed_grader_before_collect picks the
    # highest-position *failed* grader as primary, which here is g2 -- a
    # middle grader whose own next_step points at g3 (succeeded), not at
    # grader_collect.
    fanout = Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 4,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop"
    )
    first_failed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 5,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "migration-lint", "required" => true }
    )
    second_failed_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 6,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "frontend-lint", "required" => true }
    )
    later_passing_grader = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: 7,
      state: "succeeded",
      iteration: 1,
      loop_id: "grade-loop",
      details: { "name" => "feature-slugs", "required" => true }
    )
    collect = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 8,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop"
    )
    fanout.update!(next_step: first_failed_grader)
    first_failed_grader.update!(next_step: second_failed_grader)
    second_failed_grader.update!(next_step: later_passing_grader)
    later_passing_grader.update!(next_step: collect)
    [ fanout, first_failed_grader, second_failed_grader, later_passing_grader, collect ].each do |step|
      step.runs.create!(job: job, trigger_kind: "retry", state: step.succeeded? ? "succeeded" : "failed")
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    new_fanout = result.step
    new_collect = new_fanout.next_step

    expect(new_fanout).to have_attributes(kind: "grader_fanout", iteration: 1)
    expect(new_fanout.loop_id).not_to eq(fanout.loop_id)
    expect(new_collect).to have_attributes(kind: "grader_collect", iteration: 1)
    expect(fanout.reload).to be_succeeded
    expect(first_failed_grader.reload).to be_failed
    expect(second_failed_grader.reload).to be_failed
    expect(later_passing_grader.reload).to be_succeeded
    expect(collect.reload).to be_failed
    expect(collect).to be_retry_until_barrier_superseded
    expect(result.run.step).to eq(new_fanout)
  end

  it "leaves old grader runs alone when starting the replacement grade-loop fanout" do
    job = Factories.job_record(state: "failed")
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    job.repository.update!(distributed_workflow_dag_enabled: true)
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 4, state: "succeeded", iteration: 1, loop_id: "grade-loop")
    first_grader = Step.create!(workflow: workflow, kind: "grader", position: 5, state: "failed", iteration: 1, loop_id: "grade-loop", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
    second_grader = Step.create!(workflow: workflow, kind: "grader", position: 6, state: "succeeded", iteration: 1, loop_id: "grade-loop", placement_policy: Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT)
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 7, state: "failed", iteration: 1, loop_id: "grade-loop")
    fanout.update!(next_step: first_grader)
    first_grader.update!(next_step: second_grader)
    second_grader.update!(next_step: collect)
    [ first_grader, second_grader ].each { |grader| grader.update!(depends_on_ids: [ fanout.id ]) }
    collect.update!(depends_on_ids: [ first_grader.id, second_grader.id ])
    [ fanout, first_grader, second_grader, collect ].each do |step|
      step.runs.create!(job: job, trigger_kind: "retry", state: step.succeeded? ? "succeeded" : "failed")
    end

    result = described_class.call(workflow: workflow)
    new_fanout = result.step
    new_collect = new_fanout.next_step

    expect(new_fanout).to have_attributes(kind: "grader_fanout", state: "queued")
    expect(new_collect).to have_attributes(kind: "grader_collect", state: "queued")
    expect(new_collect.depends_on_step_ids).to eq([ new_fanout.id ])
    expect(first_grader.reload).to be_failed
    expect(second_grader.reload).to be_succeeded
    expect(first_grader.runs.count).to eq(1)
    expect(second_grader.runs.count).to eq(1)
    expect(collect.reload).to be_failed
    expect(collect).to be_retry_until_barrier_superseded
  end

  it "cancels active work from the superseded grade loop before starting the replacement loop" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 4, state: "succeeded", iteration: 1, loop_id: "grade-loop")
    failed_grader = Step.create!(workflow: workflow, kind: "grader", position: 5, state: "failed", iteration: 1, loop_id: "grade-loop")
    running_grader = Step.create!(workflow: workflow, kind: "grader", position: 6, state: "running", iteration: 1, loop_id: "grade-loop")
    queued_grader = Step.create!(workflow: workflow, kind: "grader", position: 7, state: "queued", iteration: 1, loop_id: "grade-loop")
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 8, state: "failed", iteration: 1, loop_id: "grade-loop")
    fanout.update!(next_step: failed_grader)
    [ failed_grader, running_grader, queued_grader ].each { |grader| grader.update!(next_step: collect, depends_on_ids: [ fanout.id ]) }
    collect.update!(depends_on_ids: [ failed_grader.id, running_grader.id, queued_grader.id ])

    failed_grader.runs.create!(job: job, trigger_kind: "retry", state: "failed")
    running_run = running_grader.runs.create!(job: job, trigger_kind: "retry", state: "running", started_at: 2.minutes.ago)
    queued_run = queued_grader.runs.create!(job: job, trigger_kind: "retry", state: "queued")
    collect.runs.create!(job: job, trigger_kind: "retry", state: "failed")
    process = SpawnedProcess.create!(
      run: running_run,
      workflow: workflow,
      kind: "grader",
      command: "bin/test",
      hostname: "worker-a",
      started_at: 2.minutes.ago
    )

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to have_attributes(kind: "grader_fanout", state: "queued")
    expect(result.step.loop_id).not_to eq("grade-loop")
    expect(failed_grader.reload).to be_failed
    expect(collect.reload).to be_failed
    expect(collect).to be_retry_until_barrier_superseded
    expect(running_grader.reload).to have_attributes(state: "cancelled", cancellation_reason: "manual_grade_loop_restart")
    expect(queued_grader.reload).to have_attributes(state: "cancelled", cancellation_reason: "manual_grade_loop_restart")
    expect(running_run.reload).to be_cancelled
    expect(queued_run.reload).to be_cancelled
    expect(process.reload.kill_requested_at).to be_present
  end

  it "restarts the grade loop from scratch when the repair step inside the loop fails" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "retry", chain_template: grade_retry_chain_template(repair_first: true))
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    repair = Step.create!(workflow: workflow, kind: "implement", position: 4, state: "failed", iteration: 1, loop_id: "grade-loop")
    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 5, state: "cancelled", iteration: 1, loop_id: "grade-loop")
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 6, state: "cancelled", iteration: 1, loop_id: "grade-loop")
    summarize = Step.create!(workflow: workflow, kind: "summarize", position: 7, state: "cancelled")
    repair.update!(next_step: fanout)
    fanout.update!(next_step: collect)
    collect.update!(next_step: summarize)
    repair.runs.create!(job: job, trigger_kind: "retry", state: "failed")

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    new_repair = result.step
    new_fanout = new_repair.next_step
    new_collect = new_fanout.next_step

    expect(new_repair).to have_attributes(kind: "implement", iteration: 1, state: "queued")
    expect(new_fanout).to have_attributes(kind: "grader_fanout", iteration: 1, state: "queued")
    expect(new_collect).to have_attributes(kind: "grader_collect", iteration: 1, state: "queued")
    expect(new_repair.loop_id).not_to eq(repair.loop_id)
    expect(repair.reload).to be_failed
    expect(fanout.reload).to be_cancelled
    expect(collect.reload).to be_cancelled
    expect(collect).to be_retry_until_barrier_superseded
    expect(summarize.reload).to be_queued
    expect(result.run.step).to eq(new_repair)
  end

  it "retries a tail step when a later retry-until barrier cleared the earlier failure" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)

    old_barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 10,
      state: "failed",
      iteration: 1,
      loop_id: "grade-loop"
    )
    repair = Step.create!(workflow: workflow, kind: "implement", position: 11, state: "succeeded", iteration: 2, loop_id: "grade-loop")
    new_barrier = Step.create!(
      workflow: workflow,
      kind: "grader_collect",
      position: 12,
      state: "succeeded",
      iteration: 2,
      loop_id: "grade-loop"
    )
    failed_tail = Step.create!(workflow: workflow, kind: "test_plan", position: 13, state: "failed")
    old_barrier.update!(next_step: repair)
    repair.update!(next_step: new_barrier)
    new_barrier.update!(next_step: failed_tail)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to eq(failed_tail)
    expect(failed_tail.reload).to be_queued
    expect(failed_tail.runs.last).to eq(result.run)
  end

  it "can create a retry run that explicitly disables provider resume" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    failed_step = Step.create!(workflow: workflow, kind: "test_plan", position: 7)
    failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow, disable_session_resume: true)

    expect(result).to be_success
    expect(result.run.parent_session_id).to eq(Steps::Base::DISABLE_AGENT_RESUME)
  end

  it "returns an active-work-lock result when retrying would contend with another WorkUnit" do
    job = Factories.job_record(state: "failed")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    unit = workflow.work_unit
    failed_step = workflow.steps.first
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    unit.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    unit.work_unit_locks.active.find_each(&:release!)
    failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    other_job = Factories.job_record(user: job.user, repository: job.repository, issue_number: 998)
    other_workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: other_job)
    other_unit = other_workflow.work_unit
    other_unit.update!(state: "running", started_at: Time.current)
    other_unit.work_unit_locks.create!(lock_key: "job:#{job.id}")

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_success
    expect(result).to be_active_work_lock
    expect(result.error).to include("active WorkUnit ##{other_unit.id} already owns job:#{job.id}")
    expect(workflow.reload).to be_failed
    expect(unit.reload).to be_failed
    expect(failed_step.reload).to be_failed
    expect(failed_step.runs).to be_empty
  end

  it "keeps the owning WorkUnit active when retrying in place" do
    job = Factories.job_record(state: "failed")
    workflow = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job)
    unit = workflow.work_unit
    failed_step = workflow.steps.first
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    unit.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    unit.work_unit_locks.active.find_each(&:release!)
    failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(workflow.reload).to be_running
    expect(unit.reload).to have_attributes(state: "running", finished_at: nil)
    expect(unit.work_unit_locks.active.pluck(:lock_key)).to eq([ "job:#{job.id}" ])
  end

  it "retries an explicitly targeted failed Step instead of a succeeded grade-loop fanout" do
    job = Factories.job_record(state: "failed")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 20, state: "succeeded", loop_id: "grade-loop", iteration: 1)
    grader = Step.create!(workflow: workflow, kind: "grader", position: 21, state: "failed", loop_id: "grade-loop", iteration: 1, details: { "name" => "tests" })
    Step.create!(workflow: workflow, kind: "grader_collect", position: 22, state: "cancelled", loop_id: "grade-loop", iteration: 1)

    result = described_class.call(workflow: workflow, failed_step: grader, restart_grade_loop: false)

    expect(result).to be_success
    expect(result.step).to eq(grader)
    expect(grader.reload).to be_queued
    expect(fanout.reload).to be_succeeded
  end

  it "revives cancelled downstream steps when retrying a failed step in place" do
    job = Factories.job_record(state: "failed", pr_number: 807, branch_name: "syrus/direct-272")
    workflow = Workflow.create!(job: job, trigger_kind: "chat_feedback")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    respond = Step.create!(workflow: workflow, kind: "respond", position: 1)
    summarize = Step.create!(workflow: workflow, kind: "summarize_amend", position: 2)
    push = Step.create!(workflow: workflow, kind: "push", position: 3)
    respond.update!(next_step_id: summarize.id)
    summarize.update!(next_step_id: push.id)
    respond.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)
    cancellation_details = {
      "cancelled_by" => "terminal_workflow_cleanup",
      "cancelled_reason" => "cancel_terminal_workflow_active_descendants",
      "cancelled_workflow_id" => workflow.id,
      "cancelled_source_step_id" => respond.id,
      "kept_context" => "preserve me"
    }
    summarize.update_columns(
      state: "cancelled",
      started_at: 8.minutes.ago,
      finished_at: 8.minutes.ago,
      cancellation_reason: "cancel_terminal_workflow_active_descendants",
      details: cancellation_details
    )
    push.update_columns(
      state: "cancelled",
      started_at: 8.minutes.ago,
      finished_at: 8.minutes.ago,
      cancellation_reason: "cancel_terminal_workflow_active_descendants",
      details: cancellation_details
    )

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(workflow.reload).to be_running
    expect(respond.reload).to be_queued
    expect(summarize.reload).to be_queued
    expect(push.reload).to be_queued
    expect(summarize.cancellation_reason).to be_nil
    expect(summarize.details).to eq("kept_context" => "preserve me")
    expect(push.cancellation_reason).to be_nil
    expect(push.details).to eq("kept_context" => "preserve me")
    expect(result.run.step).to eq(respond)
  end

  it "retries the first cancelled publication step after a recovered workflow lost its publication tail" do
    job = Factories.job_record(state: "failed", pr_number: nil, branch_name: "syrus/direct-134")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(
      state: "failed",
      failure_reason: "pr_publication_missing_after_success",
      artifacts: { "failure_reason" => "pr_publication_missing_after_success" },
      started_at: 30.minutes.ago,
      finished_at: 1.minute.ago
    )
    prepare = Step.create!(workflow: workflow, kind: "prepare", position: 1)
    summarize = Step.create!(workflow: workflow, kind: "summarize", position: 2)
    test_plan = Step.create!(workflow: workflow, kind: "test_plan", position: 3)
    pr_open = Step.create!(workflow: workflow, kind: "pr_open", position: 4)
    review_plan = Step.create!(workflow: workflow, kind: "review_plan", position: 5)
    prepare.update!(next_step_id: summarize.id)
    summarize.update!(next_step_id: test_plan.id)
    test_plan.update!(next_step_id: pr_open.id)
    pr_open.update!(next_step_id: review_plan.id)
    prepare.update_columns(state: "succeeded", started_at: 29.minutes.ago, finished_at: 28.minutes.ago)
    summarize.update_columns(state: "succeeded", started_at: 3.minutes.ago, finished_at: 2.minutes.ago)
    test_plan.update_columns(state: "cancelled", started_at: 1.minute.ago, finished_at: 1.minute.ago, cancellation_reason: "stale failure cascade")
    pr_open.update_columns(state: "cancelled", started_at: 1.minute.ago, finished_at: 1.minute.ago)
    review_plan.update_columns(state: "cancelled", started_at: 1.minute.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.step).to eq(test_plan)
    expect(workflow.reload).to be_running
    expect(test_plan.reload).to be_queued
    expect(test_plan.cancellation_reason).to be_nil
    expect(pr_open.reload).to be_queued
    expect(review_plan.reload).to be_queued
    expect(result.run.step).to eq(test_plan)
  end

  it "does not treat cancelled publication steps with historical runs as retryable" do
    job = Factories.job_record(state: "failed", pr_number: nil, branch_name: "syrus/direct-134")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(
      state: "failed",
      failure_reason: "pr_publication_missing_after_success",
      artifacts: { "failure_reason" => "pr_publication_missing_after_success" },
      started_at: 30.minutes.ago,
      finished_at: 1.minute.ago
    )
    test_plan = Step.create!(workflow: workflow, kind: "test_plan", position: 3)
    test_plan.update_columns(state: "cancelled", started_at: 1.minute.ago, finished_at: 1.minute.ago)
    test_plan.runs.create!(job: job, trigger_kind: "initial")

    expect(described_class.failed_step_for(workflow)).to be_nil
  end

  it "resumes a failed merge_train_reconcile step in place instead of rebuilding the whole train" do
    job = Factories.job_record(state: "implemented", landing_failure_reason: "merge_train workflow failed")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => 999 })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    failed_step = Step.create!(workflow: workflow, kind: "merge_train_reconcile", position: 3)
    failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow, parent_session_id: "sess_123", prompt: "resume please")

    expect(result).to be_success
    expect(result.workflow).to eq(workflow)
    expect(result.step).to eq(failed_step)
    expect(workflow.reload).to be_running
    expect(failed_step.reload).to be_queued
    expect(result.run.parent_session_id).to eq("sess_123")
    expect(result.run.prompt).to eq("resume please")
    expect(job.reload.landing_failure_reason).to be_nil
  end

  %w[merge_train_build merge_train_land].each do |failed_step_kind|
    it "rebuilds a failed merge-train instead of retrying the old #{failed_step_kind} step in place" do
      user = Factories.user(github_token: "ghp_test")
      repository = Factories.repository(user: user, auto_merge_enabled: true)
      epic = Factories.epic(user: user, repository: repository, state: "in_progress")
      job = Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        state: "approved",
        pr_number: 321,
        branch_name: "syrus/issue-321"
      )
      train = MergeTrain.create!(
        epic: epic,
        repository: repository,
        base_branch: "master",
        state: "failed",
        failure_reason: "merge_train failed",
        finished_at: 1.minute.ago
      )
      MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
      workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      failed_step = Step.create!(workflow: workflow, kind: failed_step_kind, position: 5)
      failed_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

      AppSetting.current.update!(merge_train_enabled: true)
      allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
        new_workflow.first_step.runs.create!(
          job: new_workflow.job,
          trigger_kind: new_workflow.trigger_kind,
          agent_provider: new_workflow.agent_provider
        )
      end

      result = described_class.call(workflow: workflow)

      expect(result).to be_success
      expect(result.workflow).not_to eq(workflow)
      expect(result.workflow.trigger_kind).to eq("merge_train")
      expect(result.step.kind).to eq("merge_train_assemble")
      expect(result.run.step).to eq(result.step)
      expect(workflow.reload).to be_failed
      expect(failed_step.reload).to be_failed
      expect(failed_step.runs).to be_empty
      expect(job.reload).to be_landing
    end
  end

  it "recovers and re-approves failed members from the old merge-train before rebuilding" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "failed",
      pr_number: 321,
      branch_name: "syrus/issue-321",
      approved_at: nil,
      approved_via: "operator",
      landing_failure_reason: "merge_train failed"
    )
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train failed",
      finished_at: 1.minute.ago
    )
    MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    land_step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 5)
    land_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    AppSetting.current.update!(merge_train_enabled: true)
    allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
      new_workflow.first_step.runs.create!(
        job: new_workflow.job,
        trigger_kind: new_workflow.trigger_kind,
        agent_provider: new_workflow.agent_provider
      )
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.workflow).not_to eq(workflow)
    expect(result.workflow.trigger_kind).to eq("merge_train")
    expect(job.reload).to be_landing
    expect(job.approved_at).to be_present
    expect(job.approved_via).to eq("operator")
    expect(job.landing_failure_reason).to be_nil
  end

  it "rebuilds a failed bundle-backed merge-train without routing through Epic recovery" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    Feature.create!(slug: "epicless_job_bundling", category: "Labs", name: "Epicless Job bundling", enabled: true)
    jobs = [
      Factories.job_record(
        user: user,
        repository: repository,
        epic: nil,
        state: "failed",
        priority: "medium",
        pr_number: 401,
        branch_name: "syrus/issue-401",
        landing_failure_reason: "merge_train failed"
      ),
      Factories.job_record(
        user: user,
        repository: repository,
        epic: nil,
        state: "failed",
        priority: "medium",
        pr_number: 402,
        branch_name: "syrus/issue-402",
        landing_failure_reason: "merge_train failed"
      )
    ]
    train = MergeTrain.create!(
      repository: repository,
      base_branch: "master",
      priority: "medium",
      state: "failed",
      failure_reason: "merge_train failed",
      finished_at: 1.minute.ago
    )
    jobs.each_with_index { |job, index| MergeTrainMember.create!(merge_train: train, job: job, position: index, state: "failed") }
    workflow = Workflow.create!(job: jobs.last, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    build_step = Step.create!(workflow: workflow, kind: "merge_train_build", position: 5)
    build_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
      new_workflow.first_step.runs.create!(
        job: new_workflow.job,
        trigger_kind: new_workflow.trigger_kind,
        agent_provider: new_workflow.agent_provider
      )
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.workflow).not_to eq(workflow)
    expect(result.workflow.trigger_kind).to eq("merge_train")
    expect(result.workflow.work_unit.kind).to eq("job_bundle")
    expect(result.step.kind).to eq("merge_train_assemble")
    expect(jobs.map(&:reload)).to all(be_landing)
    expect(jobs.map(&:approved_at)).to all(be_present)
    expect(jobs.map(&:landing_failure_reason)).to all(be_nil)
  end

  it "rebuilds a terminal bundle train instead of resuming final fix in the poisoned workflow" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    Feature.create!(slug: "epicless_job_bundling", category: "Labs", name: "Epicless Job bundling", enabled: true)
    jobs = [
      Factories.job_record(
        user: user,
        repository: repository,
        epic: nil,
        state: "implemented",
        priority: "medium",
        pr_number: 501,
        branch_name: "syrus/issue-501",
        approved_at: 10.minutes.ago,
        approved_via: "operator",
        landing_failure_reason: MergeTrain::STALE_RUNTIME_FAILURE_REASON
      ),
      Factories.job_record(
        user: user,
        repository: repository,
        epic: nil,
        state: "landing",
        priority: "medium",
        pr_number: 502,
        branch_name: "syrus/issue-502",
        approved_at: 10.minutes.ago,
        approved_via: "operator",
        landing_failure_reason: MergeTrain::STALE_RUNTIME_FAILURE_REASON
      )
    ]
    train = MergeTrain.create!(
      repository: repository,
      base_branch: "master",
      priority: "medium",
      state: "failed",
      failure_reason: MergeTrain::STALE_RUNTIME_FAILURE_REASON,
      finished_at: 1.minute.ago
    )
    jobs.each_with_index { |job, index| MergeTrainMember.create!(merge_train: train, job: job, position: index, state: "failed") }
    workflow = Workflow.create!(job: jobs.last, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    final_fix = Step.create!(workflow: workflow, kind: "landing_fix", position: 9)
    final_fix.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    old_unit = attach_work_unit(workflow, state: "running", kind: "job_bundle", member_jobs: jobs)

    allow(StepDispatcher).to receive(:start_workflow) do |new_workflow|
      new_workflow.first_step.runs.create!(
        job: new_workflow.job,
        trigger_kind: new_workflow.trigger_kind,
        agent_provider: new_workflow.agent_provider
      )
    end

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(result.workflow).not_to eq(workflow)
    expect(result.workflow.trigger_kind).to eq("merge_train")
    expect(result.workflow.work_unit.kind).to eq("job_bundle")
    expect(result.step.kind).to eq("merge_train_assemble")
    expect(final_fix.reload).to be_failed
    expect(old_unit.reload).to be_failed
    expect(old_unit.work_unit_locks.active).to be_empty
    expect(jobs.map(&:reload)).to all(be_landing)
    expect(jobs.map(&:approved_at)).to all(be_present)
    expect(jobs.map(&:landing_failure_reason)).to all(be_nil)
  end

  it "explains why a failed merge-train cannot be rebuilt" do
    user = Factories.user(github_token: "ghp_test")
    repository = Factories.repository(user: user, auto_merge_enabled: true)
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    job = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      pr_number: 321,
      branch_name: "syrus/issue-321"
    )
    blocker = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      state: "implemented",
      pr_number: nil,
      branch_name: "syrus/issue-322"
    )
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      state: "failed",
      failure_reason: "merge_train: missing built base SHA; rebuild required",
      finished_at: 1.minute.ago
    )
    MergeTrainMember.create!(merge_train: train, job: job, position: 0, state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    land_step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 5)
    land_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    AppSetting.current.update!(merge_train_enabled: true)

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_success
    expect(job.reload).to be_approved
    expect(result.error).to eq("Epic is not ready for a merge-train rebuild: child Jobs without a PR: #{blocker.slug}.")
  end

  it "directs the operator to admin escalation instead of Start Over when the merge train record is missing" do
    job = Factories.job_record(state: "implemented")
    workflow = Workflow.create!(job: job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => 999_999 })
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    land_step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 5)
    land_step.update_columns(state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)

    result = described_class.call(workflow: workflow)

    expect(result).not_to be_success
    expect(result.error).to eq("Merge train record not found - contact an admin or operator to rebuild the merge train.")
    expect(result.error).not_to include("Start over")
  end

  (Workflow::LANDING_TRIGGER_KINDS - [ "merge_train" ]).each do |trigger_kind|
    it "clears landing_failure_reason on the job when retrying a failed #{trigger_kind} step" do
      job = Factories.job_record(state: "implemented", landing_failure_reason: "#{trigger_kind} workflow failed")
      workflow = Workflow.create!(job: job, trigger_kind: trigger_kind)
      workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
      step = Step.create!(workflow: workflow, kind: "grader_collect", position: 1)
      step.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)

      result = described_class.call(workflow: workflow)

      expect(result).to be_success
      expect(job.reload.landing_failure_reason).to be_nil
    end
  end

  it "does not clear landing_failure_reason when retrying a non-landing workflow step" do
    job = Factories.job_record(state: "failed", landing_failure_reason: "old landing failure")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 1.minute.ago)
    step = Step.create!(workflow: workflow, kind: "pr_open", position: 1)
    step.update_columns(state: "failed", started_at: 9.minutes.ago, finished_at: 8.minutes.ago)

    result = described_class.call(workflow: workflow)

    expect(result).to be_success
    expect(job.reload.landing_failure_reason).to eq("old landing failure")
  end
end

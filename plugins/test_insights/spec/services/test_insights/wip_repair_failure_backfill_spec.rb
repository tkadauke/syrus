require "rails_helper"

RSpec.describe TestInsights::WipRepairFailureBackfill do
  let(:job)      { Factories.job }
  let(:repo)     { job.repository }
  let(:workflow) { job.initial_run.workflow }
  let(:backfill) { described_class.new }

  def create_identity(name: "flaky_case", suite_name: "MySpec")
    TestInsights::TestIdentity.create!(
      repository: repo,
      fingerprint: TestInsights::TestIdentity.fingerprint_for(suite_name: suite_name, name: name),
      suite_name: suite_name,
      name: name
    )
  end

  def create_grader_case(identity:, status:, iteration:, loop_id: "grade-loop", grader_name: "rspec")
    step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: iteration,
      iteration: iteration,
      loop_id: loop_id,
      state: status == "passed" ? "succeeded" : "failed",
      details: { "name" => grader_name }
    )
    run = Run.create!(
      job: workflow.job, user: workflow.user, step: step,
      trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: status == "passed" ? "succeeded" : "failed"
    )
    test_run = TestInsights::TestRun.create!(
      run: run, repository: repo, grader_name: grader_name,
      total_count: 1, passed_count: status == "passed" ? 1 : 0, failed_count: status == "failed" ? 1 : 0,
      skipped_count: 0, error_count: 0
    )
    test_case = TestInsights::TestCase.create!(
      test_run: test_run, repository: repo, test_identity: identity,
      name: identity.name, suite_name: identity.suite_name, status: status
    )

    [ test_run, test_case ]
  end

  def create_zero_case_grader_run(iteration:, loop_id: "grade-loop", grader_name: "rspec")
    step = Step.create!(
      workflow: workflow,
      kind: "grader",
      position: iteration,
      iteration: iteration,
      loop_id: loop_id,
      state: "succeeded",
      details: { "name" => grader_name }
    )
    run = Run.create!(
      job: workflow.job, user: workflow.user, step: step,
      trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
      state: "succeeded"
    )
    TestInsights::TestRun.create!(
      run: run, repository: repo, grader_name: grader_name,
      total_count: 0, passed_count: 0, failed_count: 0,
      skipped_count: 0, error_count: 0
    )
  end

  it "classifies historical WIP repair failures that predate the column, without touching genuine failures" do
    identity = create_identity
    _, failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    other_identity = create_identity(name: "genuinely_broken")
    _, never_fixed_case = create_grader_case(identity: other_identity, status: "failed", iteration: 1)

    # Simulate rows ingested before the classifier existed -- neither case
    # has been reclassified yet, exactly like pre-migration production data.
    expect(failing_case.wip_repair_failure).to be(false)

    result = backfill.call(limit: 200)

    expect(result.done).to be(false)
    expect(failing_case.reload.wip_repair_failure).to be(true)
    expect(never_fixed_case.reload.wip_repair_failure).to be(false)

    # A candidate batch smaller than the limit still isn't "done" until a
    # follow-up call finds nothing left -- the same terminal-empty-page
    # contract every other MaintenanceTasks definition uses.
    final_result = backfill.call(after_id: result.next_after_id, limit: 200)
    expect(final_result.done).to be(true)
  end

  it "is idempotent: re-running does not change an already-classified case" do
    identity = create_identity
    _, failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    backfill.call(limit: 200)
    expect(failing_case.reload.wip_repair_failure).to be(true)

    expect { backfill.call(limit: 200) }
      .not_to change { failing_case.reload.wip_repair_failure }
  end

  it "batches across multiple test runs using an after_id cursor" do
    identity = create_identity
    _, first_failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    first_batch = backfill.call(limit: 1)
    expect(first_batch.done).to be(false)
    expect(first_batch.processed).to eq(1)

    second_batch = backfill.call(after_id: first_batch.next_after_id, limit: 1)
    expect(second_batch.processed).to eq(1)

    expect(first_failing_case.reload.wip_repair_failure).to be(true)
  end

  it "ignores test runs whose step is not a grader retry-loop iteration" do
    step = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "succeeded", details: {})
    run = Run.create!(
      job: workflow.job, user: workflow.user, step: step,
      trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider, state: "succeeded"
    )
    TestInsights::TestRun.create!(
      run: run, repository: repo, grader_name: "rspec",
      total_count: 1, passed_count: 1, failed_count: 0, skipped_count: 0, error_count: 0
    )

    result = backfill.call(limit: 200)

    expect(result.done).to be(true)
    expect(result.processed).to eq(0)
  end

  describe ".pending_count" do
    it "counts candidate grader-retry-loop test runs" do
      identity = create_identity
      create_grader_case(identity: identity, status: "failed", iteration: 1)

      expect(described_class.pending_count).to eq(1)
    end

    it "does not count zero-case grader-retry-loop runs as pending work" do
      create_zero_case_grader_run(iteration: 1)

      expect(described_class.pending_count).to eq(0)
    end

    it "uses a completed maintenance checkpoint as the durable historical upper bound" do
      definition = MaintenanceTasks::Definitions::TestInsightsWipRepairFailureBackfill.new

      repaired_identity = create_identity(name: "repaired_case")
      _, repaired_failure = create_grader_case(identity: repaired_identity, status: "failed", iteration: 1)
      create_grader_case(identity: repaired_identity, status: "passed", iteration: 2)

      negative_identity = create_identity(name: "still_failing")
      _, negative_case = create_grader_case(identity: negative_identity, status: "failed", iteration: 3)
      create_zero_case_grader_run(iteration: 4)

      task = MaintenanceTask.create!(
        definition.build_task_attributes(
          trigger_kind: "detector",
          trigger_key: definition.key,
          task_key: "detector:#{definition.key}"
        ).merge(state: "running", batch_size: 2, total_units: definition.estimate_total_units)
      )

      5.times do
        break if task.reload.state == "succeeded"

        MaintenanceTasks::Runner.new(task).call
      end

      expect(task.reload.state).to eq("succeeded")
      expect(repaired_failure.reload.wip_repair_failure).to be(true)
      expect(negative_case.reload.wip_repair_failure).to be(false)
      expect(definition.estimate_total_units).to eq(0)

      allow(MaintenanceTasks::Registry).to receive(:all).and_return([ definition ])
      expect { MaintenanceTasks::Discovery.call }.not_to change { task.reload.state }
      expect(task.reload.state).to eq("succeeded")

      later_identity = create_identity(name: "later_case")
      create_grader_case(identity: later_identity, status: "failed", iteration: 5)

      expect(definition.estimate_total_units).to eq(0)

      MaintenanceTasks::Discovery.call

      revived_checkpoint = task.reload.checkpoint
      expect(task).to have_attributes(state: "succeeded")
      expect(revived_checkpoint["after_id"]).to be >= negative_case.test_run_id
      expect(revived_checkpoint["upper_bound_test_run_id"]).to be >= negative_case.test_run_id
      expect(definition.estimate_total_units).to eq(0)
    end

    it "revives cancelled partial work within its original bound without tailing later live rows" do
      definition = MaintenanceTasks::Definitions::TestInsightsWipRepairFailureBackfill.new

      repaired_identity = create_identity(name: "repaired_before_bound")
      _, repaired_failure = create_grader_case(identity: repaired_identity, status: "failed", iteration: 1)
      create_grader_case(identity: repaired_identity, status: "passed", iteration: 2)

      negative_identity = create_identity(name: "still_failing_before_bound")
      create_grader_case(identity: negative_identity, status: "failed", iteration: 3)

      task = MaintenanceTask.create!(
        definition.build_task_attributes(
          trigger_kind: "detector",
          trigger_key: definition.key,
          task_key: "detector:#{definition.key}"
        ).merge(state: "running", batch_size: 1, total_units: definition.estimate_total_units)
      )
      original_upper_bound = task.checkpoint.fetch("upper_bound_test_run_id")

      MaintenanceTasks::Runner.new(task).call
      expect(task.reload).to have_attributes(state: "running", completed_units: 1)

      task.update!(state: "cancelled", finished_at: Time.current, cancelled_at: Time.current)

      later_identity = create_identity(name: "later_repaired_after_bound")
      _, later_failure = create_grader_case(identity: later_identity, status: "failed", iteration: 4)
      create_grader_case(identity: later_identity, status: "passed", iteration: 5)

      allow(MaintenanceTasks::Registry).to receive(:all).and_return([ definition ])
      MaintenanceTasks::Discovery.call

      expect(task.reload).to have_attributes(state: "pending", completed_units: 0, total_units: 2)
      expect(task.checkpoint).to include(
        "after_id" => repaired_failure.test_run_id,
        "upper_bound_test_run_id" => original_upper_bound
      )

      task.update!(state: "running", batch_size: 2)
      5.times do
        break if task.reload.state == "succeeded"

        MaintenanceTasks::Runner.new(task).call
      end

      expect(task.reload).to have_attributes(state: "succeeded", completed_units: 2, total_units: 2)
      expect(repaired_failure.reload.wip_repair_failure).to be(true)
      expect(later_failure.reload.wip_repair_failure).to be(false)
    end
  end
end

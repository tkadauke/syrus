require "rails_helper"

RSpec.describe BackfillWipRepairFailuresJob do
  include ActiveJob::TestHelper

  let(:job)      { Factories.job }
  let(:repo)     { job.repository }
  let(:workflow) { job.initial_run.workflow }

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

  it "classifies historical WIP repair failures that predate the column, without touching genuine failures" do
    identity = create_identity
    _, failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    other_identity = create_identity(name: "genuinely_broken")
    _, never_fixed_case = create_grader_case(identity: other_identity, status: "failed", iteration: 1)

    # Simulate rows ingested before the classifier existed -- neither case
    # has been reclassified yet, exactly like pre-migration production data.
    expect(failing_case.wip_repair_failure).to be(false)

    perform_enqueued_jobs { described_class.perform_later }

    expect(failing_case.reload.wip_repair_failure).to be(true)
    expect(never_fixed_case.reload.wip_repair_failure).to be(false)
  end

  it "is idempotent: re-running does not change an already-classified case" do
    identity = create_identity
    _, failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    perform_enqueued_jobs { described_class.perform_later }
    expect(failing_case.reload.wip_repair_failure).to be(true)

    expect { perform_enqueued_jobs { described_class.perform_later } }
      .not_to change { failing_case.reload.wip_repair_failure }
  end

  it "batches across multiple test runs using after_id continuation" do
    stub_const("#{described_class}::BATCH_SIZE", 1)

    identity = create_identity
    _, first_failing_case = create_grader_case(identity: identity, status: "failed", iteration: 1)
    create_grader_case(identity: identity, status: "passed", iteration: 2)

    perform_enqueued_jobs { described_class.perform_later }

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

    expect { perform_enqueued_jobs { described_class.perform_later } }.not_to raise_error
  end
end

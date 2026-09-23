require "rails_helper"

RSpec.describe TestInsights::WipRepairFailureClassifier do
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

  def create_grader_case(identity:, workflow:, status:, iteration:, loop_id: "grade-loop", grader_name: "rspec")
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
      run: run, repository: identity.repository, grader_name: grader_name,
      total_count: 1, passed_count: status == "passed" ? 1 : 0, failed_count: status == "failed" ? 1 : 0,
      skipped_count: 0, error_count: 0
    )
    test_case = TestInsights::TestCase.create!(
      test_run: test_run, repository: identity.repository, test_identity: identity,
      name: identity.name, suite_name: identity.suite_name, status: status
    )

    [ test_run, step, test_case ]
  end

  it "flags an earlier same-loop failure once a later iteration passes" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1)
    passing_test_run, passing_step, = create_grader_case(identity: identity, workflow: workflow, status: "passed", iteration: 2)

    described_class.mark_superseded!(test_run: passing_test_run, step: passing_step)

    expect(failing_case.reload.wip_repair_failure).to be(true)
  end

  it "is a no-op when the step is not a grader step" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1)
    passing_test_run, passing_step, = create_grader_case(identity: identity, workflow: workflow, status: "passed", iteration: 2)
    non_grader_step = Step.create!(workflow: workflow, kind: "implement", position: 3, state: "succeeded", details: {})

    result = described_class.mark_superseded!(test_run: passing_test_run, step: non_grader_step)

    expect(result).to eq(0)
    expect(failing_case.reload.wip_repair_failure).to be(false)
  end

  it "is a no-op when the grader step has no loop_id" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1, loop_id: nil)
    passing_test_run, passing_step, = create_grader_case(identity: identity, workflow: workflow, status: "passed", iteration: 2, loop_id: nil)

    result = described_class.mark_superseded!(test_run: passing_test_run, step: passing_step)

    expect(result).to eq(0)
    expect(failing_case.reload.wip_repair_failure).to be(false)
  end

  it "does not flag a failure for a different grader name in the same loop" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1, grader_name: "rspec")
    passing_test_run, passing_step, = create_grader_case(identity: identity, workflow: workflow, status: "passed", iteration: 2, grader_name: "eslint")

    described_class.mark_superseded!(test_run: passing_test_run, step: passing_step)

    expect(failing_case.reload.wip_repair_failure).to be(false)
  end

  it "does not flag an earlier passing case's own prior failures when nothing passed this run" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1)
    another_failing_test_run, another_failing_step, = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 2)

    result = described_class.mark_superseded!(test_run: another_failing_test_run, step: another_failing_step)

    expect(result).to eq(0)
    expect(failing_case.reload.wip_repair_failure).to be(false)
  end

  it "leaves an already-flagged case alone (idempotent)" do
    identity = create_identity
    _, _, failing_case = create_grader_case(identity: identity, workflow: workflow, status: "failed", iteration: 1)
    passing_test_run, passing_step, = create_grader_case(identity: identity, workflow: workflow, status: "passed", iteration: 2)

    described_class.mark_superseded!(test_run: passing_test_run, step: passing_step)
    expect { described_class.mark_superseded!(test_run: passing_test_run, step: passing_step) }
      .not_to change { failing_case.reload.wip_repair_failure }
  end
end

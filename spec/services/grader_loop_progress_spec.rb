require "rails_helper"

RSpec.describe GraderLoopProgress do
  def add_repair(workflow, iteration:, head_sha:)
    step = workflow.steps.create!(kind: "implement", position: iteration * 10, iteration:, loop_id: "grade-loop",
      state: "succeeded")
    step.runs.create!(job: workflow.job, trigger_kind: workflow.trigger_kind, state: "succeeded", head_sha:)
  end

  def add_failed_grader(workflow, iteration:, name:, identities:, classification: nil)
    step = workflow.steps.create!(kind: "grader", position: iteration * 10 + 1, iteration:, loop_id: "grade-loop",
      state: "failed", details: { "name" => name, "required" => true })
    run = step.runs.create!(job: workflow.job, trigger_kind: workflow.trigger_kind, state: "failed")
    run.create_run_failure_classification!(classification:, retryable: true, confidence: 0.9,
      classified_at: Time.current) if classification
    allow(TestEvidenceLookup).to receive(:failed_test_cases_for).with(run, name)
      .and_return(identities.map { |identity| { "identity" => identity } })
    step
  end

  def collect(workflow, iteration:)
    workflow.steps.create!(kind: "grader_collect", position: iteration * 10 + 2, iteration:,
      loop_id: "grade-loop", state: "failed")
  end

  it "excludes inconclusive rounds and graders while retaining compared revisions for a no-progress stop" do
    job = Factories.job_record(state: "running")
    workflow = Workflow.create!(job:, trigger_kind: "initial", state: "running")

    add_repair(workflow, iteration: 1, head_sha: "source-sha")
    add_failed_grader(workflow, iteration: 1, name: "infrastructure", identities: [ "timed out" ],
      classification: "timeout")
    expect(described_class.record_failure!(workflow:, collect_step: collect(workflow, iteration: 1))).not_to be_stop

    add_repair(workflow, iteration: 2, head_sha: "first-repair-sha")
    add_failed_grader(workflow, iteration: 2, name: "frontend", identities: [ "frontend renders recovery" ])
    expect(described_class.record_failure!(workflow:, collect_step: collect(workflow, iteration: 2))).not_to be_stop

    add_repair(workflow, iteration: 3, head_sha: "second-repair-sha")
    add_failed_grader(workflow, iteration: 3, name: "frontend", identities: [ "frontend renders recovery" ])
    add_failed_grader(workflow, iteration: 3, name: "unrelated", identities: [ "timed out again" ],
      classification: "timeout")
    result = described_class.record_failure!(workflow:, collect_step: collect(workflow, iteration: 3))

    expect(result).to be_stop
    rounds = workflow.reload.artifact(described_class::ARTIFACT_KEY)
    expect(rounds.first).to include("transient_only" => true, "failing_set" => [])
    expect(rounds.second).to include(
      "source_revision" => "source-sha", "repaired_revision" => "first-repair-sha",
      "failing_set" => [ "frontend renders recovery" ]
    )
    expect(rounds.third).to include(
      "source_revision" => "first-repair-sha", "repaired_revision" => "second-repair-sha",
      "failing_set" => [ "frontend renders recovery" ]
    )
    expect(RecoveryDecision.for(job:, workflow:)).to have_attributes(
      kind: "grader_loop_no_progress", recommended_action: "repair_with_guidance"
    )
  end
end

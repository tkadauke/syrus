require "rails_helper"

RSpec.describe RecoveryContract do
  it "summarizes a mixed no-progress loop without letting infrastructure noise affect the decision" do
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job:, trigger_kind: "initial", state: "failed")
    collect = workflow.steps.create!(kind: "grader_collect", position: 9, state: "failed", loop_id: "grade-loop", iteration: 3)
    collect_run = collect.runs.create!(job:, trigger_kind: "initial", state: "failed")
    infrastructure = workflow.steps.create!(kind: "grader", position: 8, state: "failed", loop_id: "grade-loop", iteration: 3)
    infrastructure_run = infrastructure.runs.create!(job:, trigger_kind: "initial", state: "failed")
    infrastructure_run.create_run_failure_classification!(classification: "timeout", retryable: true,
      confidence: 0.9, classified_at: Time.current)
    rounds = [
      { "loop_id" => "grade-loop", "iteration" => 2, "source_revision" => "source-sha",
        "repaired_revision" => "repair-one", "failing_set" => [ "frontend renders recovery" ] },
      { "loop_id" => "grade-loop", "iteration" => 3, "source_revision" => "repair-one",
        "repaired_revision" => "repair-two", "failing_set" => [ "frontend renders recovery" ],
        "grader_results" => [ { "name" => "frontend" },
          { "name" => "worker timeout", "step_id" => infrastructure.id, "run_id" => infrastructure_run.id, "timed_out" => true } ] }
    ]
    workflow.set_artifact!(GraderLoopProgress::ARTIFACT_KEY, rounds)
    workflow.set_artifact!(GraderLoopProgress::STOP_ARTIFACT_KEY, {
      "reason" => GraderLoopProgress::NO_PROGRESS_REASON, "explanation" => "failing set unchanged",
      "previous_iteration" => 2, "current_iteration" => 3,
      "failing_set" => [ "frontend renders recovery" ], "rounds" => rounds
    })

    payload = described_class.for_workflow(workflow)

    expect(payload.dig(:decision, :outcome)).to eq("measured_failure")
    expect(payload.dig(:decision, :measured_failures)).to eq([ "frontend renders recovery" ])
    expect(payload.dig(:decision, :inconclusive_infrastructure_failures)).to contain_exactly(
      include(name: "worker timeout", classification: "timeout", affected_decision: false)
    )
    expect(payload.dig(:decision, :compared_repair_iterations).map { |round| round[:repaired_revision] })
      .to eq(%w[repair-one repair-two])
    expect(payload.dig(:decision, :references)).to include(job: "JOB-#{job.id}", source_workflow: "WF-#{workflow.id}",
      source_step: "STEP-#{collect.id}", source_run: "RUN-#{collect_run.id}")
  end

  it "bounds intervention history and operator-authored text" do
    job = Factories.job_record(state: "failed")
    25.times do |index|
      job.recovery_interventions.create!(actor_type: "agent", actor_display: "Recovery agent", origin: "mcp_retry_job",
        action: "repair", recovery_kind: "measured_failure", recovery_mode: "failed_step",
        guidance: "g" * 2_000, failure_evidence: {}, performed_at: index.minutes.ago)
    end

    payload = described_class.for_job(job)

    expect(payload.dig(:interventions, :items).size).to eq(described_class::HISTORY_LIMIT)
    expect(payload.dig(:interventions, :total)).to eq(25)
    expect(payload.dig(:interventions, :truncated)).to be(true)
    expect(payload.dig(:interventions, :items, 0, :guidance).length).to eq(described_class::TEXT_LIMIT)
    expect(payload.to_json.bytesize).to be < 40.kilobytes
  end
end

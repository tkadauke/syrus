require "rails_helper"

RSpec.describe RecoveryDecision do
  def failed_workflow(cleaned_up_at: nil)
    job = Factories.job_record(state: "failed")
    workflow = Workflow.create!(job:, trigger_kind: "initial", state: "failed", cleaned_up_at:)
    [ job, workflow ]
  end

  it "recommends guided repair and retains measured no-progress evidence" do
    job, workflow = failed_workflow
    workflow.set_artifact!(GraderLoopProgress::STOP_ARTIFACT_KEY, {
      "reason" => GraderLoopProgress::NO_PROGRESS_REASON,
      "previous_iteration" => 2,
      "current_iteration" => 3,
      "explanation" => "failing set unchanged",
      "failing_set" => [ "frontend\0renders the recovery action" ],
      "rounds" => [
        { "iteration" => 2, "failing_set" => [ "frontend\0renders the recovery action" ] },
        { "iteration" => 3, "failing_set" => [ "frontend\0renders the recovery action" ],
          "grader_results" => [ { "name" => "frontend" }, { "name" => "unrelated timeout" } ] }
      ]
    })

    decision = described_class.for(job:, workflow:)

    expect(decision).to have_attributes(kind: "grader_loop_no_progress", recommended_action: "repair_with_guidance", mode: "failed_step")
    expect(decision.evidence[:measured_failure_identities]).to eq([ "frontend\0renders the recovery action" ])
    expect(decision.evidence[:compared_iterations]).to include("previous_iteration" => 2, "current_iteration" => 3)
  end

  it "recommends a fresh implementation when the workspace is unavailable" do
    job, workflow = failed_workflow(cleaned_up_at: Time.current)

    expect(described_class.for(job:, workflow:)).to have_attributes(
      kind: "workspace_unavailable", recommended_action: "fresh_implementation", mode: "implementation"
    )
  end

  it "allows an unchanged rerun only for inconclusive infrastructure execution" do
    job, workflow = failed_workflow
    workflow.set_artifact!(GraderLoopProgress::ARTIFACT_KEY, [
      { "iteration" => 1, "transient_only" => true, "failing_set" => [] }
    ])

    expect(described_class.for(job:, workflow:)).to have_attributes(
      kind: "infrastructure_only", recommended_action: "rerun_unchanged"
    )
  end
end

require "rails_helper"

RSpec.describe RecoveryInterventions::Perform do
  it "records the manual actor, source loop, evidence, and resulting loop" do
    user = Factories.user(first_name: "Manual", last_name: "Operator")
    job = Factories.job_record(user:, state: "failed")
    source = Workflow.create!(job:, trigger_kind: "initial", state: "failed")
    fanout = Step.create!(workflow: source, kind: "grader_fanout", state: "failed", position: 1,
      loop_id: "source-loop", iteration: 2)
    source.set_artifact!(GraderLoopProgress::STOP_ARTIFACT_KEY, {
      "previous_iteration" => 1, "current_iteration" => 2,
      "explanation" => "failing set unchanged", "failing_set" => [ "frontend\0failure" ]
    })
    resulting = Workflow.create!(job:, trigger_kind: "retry", state: "queued")
    resulting_step = Step.create!(workflow: resulting, kind: "grader_fanout", state: "queued", position: 1,
      loop_id: "result-loop", iteration: 1)
    result = Struct.new(:workflow, :step, :run) { def success? = true }.new(resulting, resulting_step, nil)

    described_class.call(job:, source_workflow: source, action: "restart_grade_loop", mode: "failed_step",
      actor_type: "operator", actor: user, origin: "job_page", reason: "Try the measured fix",
      guidance: "Repair the frontend assertion") { result }

    record = RecoveryIntervention.last
    expect(record).to have_attributes(
      job:, source_workflow: source, source_step: fanout, resulting_workflow: resulting,
      resulting_step:, source_loop_id: "source-loop", actor_type: "operator", actor_id: user.id,
      resulting_loop_id: "result-loop",
      origin: "job_page", action: "restart_grade_loop", recovery_kind: "grader_loop_no_progress",
      reason: "Try the measured fix", guidance: "Repair the frontend assertion"
    )
    expect(record.failure_evidence).to include("measured_failure_identities" => [ "frontend\0failure" ])
  end

  it "preserves unknown attribution honestly" do
    job = Factories.job_record(state: "failed")
    source = Workflow.create!(job:, trigger_kind: "initial", state: "failed", cleaned_up_at: Time.current)
    resulting = Workflow.create!(job:, trigger_kind: "retry", state: "queued")
    result = RetryWorkflowEnqueuer::Result.new(workflow: resulting, error: nil, circuit: nil)

    described_class.call(job:, source_workflow: source, action: "restart", mode: "implementation",
      actor_type: "unknown", origin: "historical") { result }

    expect(RecoveryIntervention.last).to have_attributes(actor_type: "unknown", actor_id: nil, actor_display: nil)
  end
end

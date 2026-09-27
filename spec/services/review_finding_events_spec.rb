require "rails_helper"

RSpec.describe ReviewFindingEvents do
  it "broadcasts a job-scoped workflow event for a recorded review finding" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", chain_template: [])
    step = Step.create!(workflow: workflow, kind: "visual_review", position: 1, iteration: 2)
    run = Run.create!(job: job, step: step, trigger_kind: "initial")

    allow(AppEvents).to receive(:broadcast_job_resource)

    described_class.record(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: "visual",
      iteration: 2,
      verdict: "skipped",
      critique: "No affected preview project has a preview configured.",
      skipped: true,
      skip_reason: "no_affected_preview_project"
    )

    expect(AppEvents).to have_received(:broadcast_job_resource).with(
      job_id: job.id,
      type: "review_finding.recorded",
      resource: "workflow",
      id: workflow.id,
      changed: [ "visual.iterations" ],
      payload: {
        workflow_id: workflow.id,
        step_id: step.id,
        run_id: run.id,
        review_kind: "visual",
        iteration: 2,
        verdict: "skipped",
        critique: "No affected preview project has a preview configured.",
        skipped: true,
        skip_reason: "no_affected_preview_project"
      }
    )
  end
end

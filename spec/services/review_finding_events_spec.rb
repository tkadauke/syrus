require "rails_helper"

RSpec.describe ReviewFindingEvents do
  it "broadcasts a job update with review finding details" do
    job = Factories.job
    workflow = job.workflows.last
    step = workflow.steps.find_by!(kind: "implement")
    run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind)

    allow(AppEvents).to receive(:broadcast)

    described_class.record(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: "visual",
      iteration: 1,
      verdict: "skipped",
      critique: "No changed files matched.",
      skipped: true,
      skip_reason: "visual_review_when_files_changed_no_match"
    )

    expect(AppEvents).to have_received(:broadcast).with(
      user: job.user,
      type: "job.updated",
      resource: "job",
      id: job.id,
      changed: [ "review_finding.visual" ],
      revision: job.entity_revision,
      payload: include(
        review_kind: "visual",
        workflow_id: workflow.id,
        step_id: step.id,
        run_id: run.id,
        iteration: 1,
        verdict: "skipped",
        critique: "No changed files matched.",
        skipped: true,
        skip_reason: "visual_review_when_files_changed_no_match"
      )
    )
  end
end

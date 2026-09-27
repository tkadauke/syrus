require "rails_helper"

RSpec.describe Mcp::Tools::SubmitVisualReviewTool do
  let(:run) do
    job = Factories.job
    workflow = job.latest_workflow
    step = Step.create!(workflow: workflow, kind: "visual_review", position: 99)
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end

  it "records visual review findings and broadcasts a review-finding event" do
    expect(ReviewFindingEvents).to receive(:record).with(
      workflow: run.workflow,
      step: run.step,
      run: run,
      review_kind: "visual",
      iteration: run.step.iteration,
      verdict: "approved",
      critique: "The UI looks correct.",
      skipped: false
    )

    response = described_class.call(
      critique: "The UI looks correct.",
      verdict: "approved",
      server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("visual_review_iterations")).to eq([
      {
        "iteration" => run.step.iteration,
        "step_id" => run.step_id,
        "run_id" => run.id,
        "critique" => "The UI looks correct.",
        "verdict" => "approved",
        "artifacts" => []
      }
    ])
  end
end

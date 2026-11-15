require "rails_helper"
RSpec.describe Coworkers::SubmitReviewTool do
  it "persists a coworker verdict" do
    job = Factories.job
    step = Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99)
    run = step.runs.create!(job: job, trigger_kind: "initial")
    response = described_class.call(critique: "Clean.", verdict: "approved", server_context: { run: run })
    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("coworker_review_iterations")).to include(hash_including("verdict" => "approved"))
  end
end

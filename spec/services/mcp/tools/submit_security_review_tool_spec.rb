require "rails_helper"

RSpec.describe Mcp::Tools::SubmitSecurityReviewTool do
  let(:run) do
    job = Factories.job
    workflow = job.latest_workflow
    step = Step.create!(workflow: workflow, kind: "security_review", position: 99)
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
  end

  it "persists findings and records a security finding event" do
    expect(ReviewFindingEvents).to receive(:record).with(hash_including(review_kind: "security", verdict: "needs_work"))

    response = described_class.call(
      critique: "Authorization is missing.", verdict: "needs_work", server_context: { run: run }
    )

    expect(response).not_to be_error
    expect(run.workflow.reload.artifact("security_review_iterations")).to include(
      hash_including("critique" => "Authorization is missing.", "verdict" => "needs_work")
    )
  end

  it "rejects invalid verdicts" do
    response = described_class.call(critique: "Maybe", verdict: "unknown", server_context: { run: run })
    expect(response).to be_error
  end
end

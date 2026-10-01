require "rails_helper"

RSpec.describe Steps::ReviewPlan do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { Step.create!(workflow: workflow, kind: "review_plan", position: 100) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "initial") }

  it "marks persisted legacy review_plan steps as retired without invoking an agent" do
    handler = described_class.new(run)

    expect(handler).not_to receive(:run_agent)

    handler.call

    expect(step.reload.details).to include(
      "skipped" => true,
      "skip_reason" => "review_plan_retired"
    )
    expect(job.job_logs.last.chunk).to include("retired legacy PR-comment step")
  end
end

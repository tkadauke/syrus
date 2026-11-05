require "rails_helper"
RSpec.describe Steps::CoworkerReview do
  it "hard-fails before invocation without a pinned reviewer" do
    job = Factories.job
    step = Step.create!(workflow: job.latest_workflow, kind: "coworker_review", position: 99)
    run = step.runs.create!(job: job, trigger_kind: "initial")
    expect { described_class.new(run).call }.to raise_error(ProviderRouting::Resolver::CoworkerReviewTargetRequired)
  end
end

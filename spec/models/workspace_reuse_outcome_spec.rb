require "rails_helper"

RSpec.describe WorkspaceReuseOutcome, type: :model do
  it "prunes through the registry-driven retention executor" do
    job = Factories.job
    workflow = job.workflows.last
    step = workflow.steps.first
    run = step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
    attributes = {
      repository: job.repository, workflow: workflow, step: step, run: run,
      kind: "prepare", outcome: "rebuilt", backend: "local"
    }
    old = described_class.create!(**attributes, occurred_at: 91.days.ago)
    fresh = described_class.create!(**attributes, occurred_at: 1.day.ago)
    definition = RetentionPolicyRegistry.fetch(:workspace_reuse_outcome)

    result = RetentionPolicyExecutors::Default.new(definition).call

    expect(result.deleted_count).to eq(1)
    expect(described_class.exists?(old.id)).to be(false)
    expect(described_class.exists?(fresh.id)).to be(true)
  end
end

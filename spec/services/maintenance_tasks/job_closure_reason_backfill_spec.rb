require "rails_helper"

RSpec.describe MaintenanceTasks::Definitions::JobClosureReasonBackfill do
  let(:definition) { described_class.new }
  let(:task) { MaintenanceTask.new(checkpoint: {}) }

  it "maps legacy reasons in an idempotent primary-key batch" do
    no_change = Factories.job(state: "closed", closure_reason: "no_changes")
    approved = Factories.job(state: "closed", closure_reason: "pr_approved", landed_sha: "abc123")

    result = definition.perform_batch(task)

    expect(result.processed).to be >= 2
    expect(no_change.reload.closure_reason).to eq("not_needed")
    expect(approved.reload.closure_reason).to eq("pr_merged")
    expect(definition.perform_batch(task).processed).to eq(0)
  end

  it "retains an ambiguous human cancellation" do
    cancelled = Factories.job(state: "closed", closure_reason: "cancelled")

    definition.perform_batch(task)

    expect(cancelled.reload.closure_reason).to eq("cancelled")
  end
end

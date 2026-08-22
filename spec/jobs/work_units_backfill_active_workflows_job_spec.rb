require "rails_helper"

RSpec.describe WorkUnitsBackfillActiveWorkflowsJob do
  it "delegates to the active workflow backfill service" do
    expect(WorkUnits::Backfill).to receive(:active!).with(limit: 25)

    described_class.perform_now(limit: 25)
  end
end

require "rails_helper"

RSpec.describe WorkUnitsBackfillActiveWorkflowsJob do
  it "backfills a bounded batch by default" do
    expect(WorkUnits::Backfill).to receive(:active!).with(limit: described_class::DEFAULT_LIMIT)

    described_class.perform_now
  end

  it "delegates to the active workflow backfill service" do
    expect(WorkUnits::Backfill).to receive(:active!).with(limit: 25)

    described_class.perform_now(limit: 25)
  end
end

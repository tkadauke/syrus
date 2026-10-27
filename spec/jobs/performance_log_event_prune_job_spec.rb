require "rails_helper"

RSpec.describe PerformanceLogEventPruneJob do
  it "deletes only prunable events and is idempotent" do
    stale = PerformanceLogEvent.create!(occurred_at: 25.hours.ago, event_name: "sql", payload: {})
    fresh = PerformanceLogEvent.create!(occurred_at: 1.hour.ago, event_name: "sql", payload: {})

    expect { described_class.perform_now }.to change(PerformanceLogEvent, :count).by(-1)
    expect(PerformanceLogEvent.exists?(stale.id)).to be(false)
    expect(PerformanceLogEvent.exists?(fresh.id)).to be(true)
    expect { described_class.perform_now }.not_to change(PerformanceLogEvent, :count)
  end
end

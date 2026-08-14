require "rails_helper"

RSpec.describe FlushObservabilityEventsJob do
  it "flushes buffered events and deletes expired performance log events" do
    stale = PerformanceLogEvent.create!(occurred_at: 7.hours.ago, event_name: "sql", payload: {})
    fresh = PerformanceLogEvent.create!(occurred_at: 1.hour.ago, event_name: "sql", payload: {})

    expect(Observability::EventSink).to receive(:flush!)

    described_class.new.perform

    expect(PerformanceLogEvent.exists?(stale.id)).to eq(false)
    expect(PerformanceLogEvent.exists?(fresh.id)).to eq(true)
  end
end

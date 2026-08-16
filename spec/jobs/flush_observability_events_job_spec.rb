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

  it "bounds expired log deletes per run" do
    stub_const("FlushObservabilityEventsJob::DELETE_BATCH_SIZE", 2)
    stub_const("FlushObservabilityEventsJob::MAX_DELETE_BATCHES", 1)
    stale = 3.times.map { PerformanceLogEvent.create!(occurred_at: 7.hours.ago, event_name: "sql", payload: {}) }
    allow(Observability::EventSink).to receive(:flush!)

    described_class.new.perform

    remaining_ids = PerformanceLogEvent.where(id: stale.map(&:id)).pluck(:id)
    expect(remaining_ids.size).to eq(1)
  end
end

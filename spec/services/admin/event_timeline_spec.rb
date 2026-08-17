require "rails_helper"

RSpec.describe Admin::EventTimeline do
  it "builds bounded timeline buckets for an event scope" do
    user = Factories.user
    BrowserErrorEvent.record!(
      user: user,
      payload: {
        "occurred_at" => 30.minutes.ago.iso8601,
        "fingerprint" => "timeline-one",
        "message" => "first"
      }
    )
    BrowserErrorEvent.record!(
      user: user,
      payload: {
        "occurred_at" => 10.minutes.ago.iso8601,
        "fingerprint" => "timeline-two",
        "message" => "second"
      }
    )

    buckets = described_class.build(BrowserErrorEvent.all, since_time: 1.hour.ago, until_time: Time.current)

    expect(buckets.size).to be_between(1, described_class::MAX_BUCKETS)
    expect(buckets.sum { |bucket| bucket.fetch(:count) }).to eq(2)
  end
end

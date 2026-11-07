require "rails_helper"

RSpec.describe Calendar::EventQuery do
  let(:user) { Factories.user }
  let(:starts_at) { Time.zone.parse("2026-11-02 00:00:00") }
  let(:ends_at) { starts_at + 7.days }

  it "requires a bounded range" do
    expect { described_class.call(user:, starts_at:, ends_at: starts_at + 43.days) }
      .to raise_error(ArgumentError, /42 days/)
  end

  it "validates provider results and isolates a failing provider" do
    good = Class.new do
      def self.calendar_events(user:, starts_at:, ends_at:)
        [ { source_id: "calendar:test", id: "one", kind: "test", title: user.name || "Test",
            starts_at:, destination_path: "/test", state: "planned" } ]
      end
    end
    bad = Class.new { def self.calendar_events(**) = raise("unavailable") }
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with("calendar:event_source").and_return([ bad, good ])
    allow(Rails.error).to receive(:report)

    result = described_class.call(user:, starts_at:, ends_at:)

    expect(result[:events]).to contain_exactly(include(source_id: "calendar:test", id: "one"))
    expect(result[:failures]).to eq([ { source: bad.to_s, code: "provider_failed" } ])
    expect(Rails.error).to have_received(:report).with(instance_of(RuntimeError), handled: true, context: hash_including(:calendar_provider))
  end
end

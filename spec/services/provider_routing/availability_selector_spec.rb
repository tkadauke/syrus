require "rails_helper"

RSpec.describe ProviderRouting::AvailabilitySelector::Decision do
  def candidate(provider:)
    ProviderRouting::AvailabilitySelector.candidate(provider: provider)
  end

  def decision(availability:)
    described_class.new(
      candidate: candidate(provider: "codex"),
      original_candidate: candidate(provider: "claude"),
      reason: "provider_usage_exhausted",
      availability: availability,
      candidate_availability: nil,
      decided_at: Time.zone.parse("2026-01-01T00:00:00Z"),
      exhausted: false
    )
  end

  describe "#artifact" do
    it "surfaces the earliest reset_at from the real producer shape (string window keys, symbol reset_at key)" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: "2026-01-01T05:00:00Z" },
            "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
          }
        }
      }

      artifact = decision(availability: availability).artifact

      expect(artifact.dig("unavailable", "reset_at")).to be_a(String).and eq("2026-01-01T05:00:00Z")
    end

    it "does not raise ArgumentError when reset_at values are a mix of Time objects and ISO8601 strings" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: Time.zone.parse("2026-01-01T05:00:00Z") },
            "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
          }
        }
      }

      expect { decision(availability: availability).artifact }.not_to raise_error
      expect(decision(availability: availability).artifact.dig("unavailable", "reset_at")).to be_a(String).and eq("2026-01-01T05:00:00Z")
    end

    it "serializes reset_at as a plain ISO8601 string across a JSON round-trip, matching sibling timestamp fields" do
      availability = {
        state: "exhausted",
        usage: {
          windows: {
            "five_hour" => { reset_at: "2026-01-01T05:00:00Z" }
          }
        }
      }

      artifact = decision(availability: availability).artifact
      round_tripped = ActiveSupport::JSON.decode(ActiveSupport::JSON.encode(artifact))

      expect(round_tripped.dig("unavailable", "reset_at")).to eq("2026-01-01T05:00:00Z")
    end

    it "omits reset_at when no window carries one" do
      availability = { state: "exhausted", usage: {} }

      artifact = decision(availability: availability).artifact

      expect(artifact.dig("unavailable", "reset_at")).to be_nil
    end
  end
end

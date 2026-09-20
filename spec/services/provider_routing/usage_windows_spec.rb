require "rails_helper"

RSpec.describe ProviderRouting::UsageWindows do
  describe ".earliest_reset_at" do
    it "reads the real producer shape: string outer window keys, symbol inner keys" do
      usage = {
        windows: {
          "five_hour" => { reset_at: "2026-01-01T05:00:00Z" },
          "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
        }
      }

      expect(described_class.earliest_reset_at(usage)).to eq(Time.zone.parse("2026-01-01T05:00:00Z"))
    end

    it "tolerates a string-keyed usage hash and symbol-keyed windows hash" do
      usage = {
        "windows" => {
          five_hour: { "reset_at" => "2026-01-01T05:00:00Z" },
          weekly: { "reset_at" => "2026-01-05T00:00:00Z" }
        }
      }

      expect(described_class.earliest_reset_at(usage)).to eq(Time.zone.parse("2026-01-01T05:00:00Z"))
    end

    it "does not raise when one window carries a Time object and another an ISO8601 string, and returns the earlier one" do
      earlier_time = Time.zone.parse("2026-01-01T05:00:00Z")
      later_string = "2026-01-05T00:00:00Z"
      usage = {
        windows: {
          "five_hour" => { reset_at: earlier_time },
          "weekly" => { reset_at: later_string }
        }
      }

      expect { described_class.earliest_reset_at(usage) }.not_to raise_error
      expect(described_class.earliest_reset_at(usage)).to eq(earlier_time)
    end

    it "ignores an unparsable reset_at value instead of raising" do
      usage = {
        windows: {
          "five_hour" => { reset_at: "not-a-time" },
          "weekly" => { reset_at: "2026-01-05T00:00:00Z" }
        }
      }

      expect(described_class.earliest_reset_at(usage)).to eq(Time.zone.parse("2026-01-05T00:00:00Z"))
    end

    it "returns nil when usage has no windows" do
      expect(described_class.earliest_reset_at({})).to be_nil
      expect(described_class.earliest_reset_at({ windows: {} })).to be_nil
    end
  end
end

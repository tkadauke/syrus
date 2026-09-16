require "rails_helper"

RSpec.describe OperationalLogEvent do
  def event(occurred_at:)
    described_class.create!(
      occurred_at: occurred_at,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "hello",
      context: {}
    )
  end

  describe ".expired scope" do
    it "includes events older than the retention window" do
      old = event(occurred_at: (described_class.retention_window + 1.minute).ago)
      fresh = event(occurred_at: 1.minute.ago)

      expect(described_class.expired).to include(old)
      expect(described_class.expired).not_to include(fresh)
    end

    it "returns none when retention is set to 0 (infinite)" do
      AppSetting.current.update!(operational_log_event_retention_hours: 0)
      old = event(occurred_at: 10.years.ago)

      expect(described_class.expired).to be_empty
      expect(described_class.exists?(old.id)).to be true
    end
  end

  describe ".retention_window" do
    it "defaults to 6 hours" do
      expect(described_class.retention_window).to eq(6.hours)
    end
  end

  describe ".retention_floor" do
    it "clamps to now minus the configured window" do
      freeze_time do
        expect(described_class.retention_floor(now: Time.current)).to eq(Time.current - described_class.retention_window)
      end
    end

    it "returns the epoch when retention is set to 0 (infinite)" do
      AppSetting.current.update!(operational_log_event_retention_hours: 0)

      expect(described_class.retention_floor(now: Time.current)).to eq(Time.at(0))
    end
  end
end

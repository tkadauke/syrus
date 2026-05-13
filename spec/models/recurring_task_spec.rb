require "rails_helper"

RSpec.describe RecurringTask do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def task(**overrides)
    described_class.new({
      user: user,
      repository: repository,
      label: "Morning cleanup",
      prompt: "Keep this repository tidy.",
      cron_expression: "0 9 * * *"
    }.merge(overrides))
  end

  it "assigns next_fire_at from the cron expression on create" do
    travel_to Time.utc(2026, 5, 13, 8, 30, 0) do
      record = task
      record.save!

      expect(record.next_fire_at).to eq(Time.utc(2026, 5, 13, 9, 0, 0))
    end
  end

  it "rejects malformed cron expressions" do
    record = task(cron_expression: "bogus")

    expect(record).not_to be_valid
    expect(record.errors[:cron_expression]).to be_present
  end

  it "advances from the supplied time, skipping downtime backfill" do
    travel_to Time.utc(2026, 5, 13, 12, 0, 0) do
      record = task(cron_expression: "0 * * * *")
      record.save!
      record.update!(next_fire_at: 2.hours.ago)

      record.advance!(from: Time.current)

      expect(record.next_fire_at).to eq(Time.utc(2026, 5, 13, 13, 0, 0))
    end
  end
end

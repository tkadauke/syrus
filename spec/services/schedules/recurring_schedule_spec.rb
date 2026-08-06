require "rails_helper"

RSpec.describe Schedules::RecurringSchedule do
  it "converts the live weekly cron shape to canonical RRULE" do
    result = described_class.preview(input: "0 9 * * 1", from: Time.utc(2026, 8, 5, 8, 0, 0))

    expect(result).to be_valid
    expect(result.expression).to eq("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
    expect(result.explanation).to eq("Every Monday at 9:00 AM UTC")
    expect(result.next_fire_at).to eq("2026-08-10T09:00:00Z")
  end

  it "preserves annual cron semantics as yearly recurrence" do
    result = described_class.preview(input: "0 9 14 8 *", from: Time.utc(2026, 8, 5, 0, 0, 0))

    expect(result).to be_valid
    expect(result.expression).to eq("FREQ=YEARLY;BYMONTH=8;BYMONTHDAY=14;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
    expect(result.explanation).to eq("Every August 14 at 9:00 AM UTC")
    expect(result.next_fire_at).to eq("2026-08-14T09:00:00Z")
  end

  it "keeps fixed-minute hourly cron compatible" do
    result = described_class.preview(input: "0 * * * *", from: Time.utc(2026, 8, 5, 8, 30, 0))

    expect(result).to be_valid
    expect(result.expression).to eq("FREQ=HOURLY;BYMINUTE=0;BYSECOND=0")
    expect(result.explanation).to eq("Every hour at 00 minutes past the hour UTC")
    expect(result.next_fire_at).to eq("2026-08-05T09:00:00Z")
  end

  it "parses supported natural cadence text deterministically" do
    result = described_class.preview(input: "Every Monday at 9am")

    expect(result).to be_valid
    expect(result.expression).to eq("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
    expect(result.cron_expression).to be_nil
  end

  it "rejects natural typos without structured intent" do
    result = described_class.preview(input: "modays at 9")

    expect(result).not_to be_valid
    expect(result.errors).to include("Schedule input is not a supported cadence or five-field cron expression")
  end

  it "accepts typo resolution only when supplied as structured intent" do
    result = described_class.preview(
      input: "modays at 9",
      structured_intent: { frequency: "weekly", day: "monday", hour: 9, minute: 0 }
    )

    expect(result).to be_valid
    expect(result.explanation).to eq("Every Monday at 9:00 AM UTC")
  end

  it "rejects cron that can fire more than once per hour" do
    result = described_class.preview(input: "*/30 * * * *")

    expect(result).not_to be_valid
    expect(result.errors.join).to include("at most once per hour")
  end

  it "computes due windows without duplicate minute-level fires" do
    expression = "FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0"

    expect(described_class.due_window_start(expression, now: Time.utc(2026, 8, 10, 8, 59))).to be_nil
    expect(described_class.due_window_start(expression, now: Time.utc(2026, 8, 10, 9, 1))).to eq(Time.utc(2026, 8, 10, 9))
    expect(described_class.due_window_start(expression, now: Time.utc(2026, 8, 10, 10, 0))).to be_nil
  end
end

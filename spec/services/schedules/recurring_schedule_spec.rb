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
    expect(result.source).to eq("natural")
  end

  describe "strict cron-shape detection" do
    it "does not route five-token natural language through the cron parser" do
      expect(described_class.cron_shaped?("Every day at 10 am")).to be(false)
      expect(described_class.cron_shaped?("Every Monday at 9:00 AM")).to be(false)
    end

    it "still recognizes genuine five-field cron" do
      expect(described_class.cron_shaped?("0 9 * * 1")).to be(true)
      expect(described_class.cron_shaped?("*/30 * * * *")).to be(true)
    end
  end

  it "previews the exact UI placeholder successfully" do
    result = described_class.preview(input: "Every Monday at 9:00 AM", from: Time.utc(2026, 8, 5, 8, 0, 0))

    expect(result).to be_valid
    expect(result.explanation).to eq("Every Monday at 9:00 AM UTC")
    expect(result.source).to eq("natural")
  end

  it "parses the previously-broken spaced meridiem cadence deterministically" do
    result = described_class.preview(input: "Every day at 10 am")

    expect(result).to be_valid
    expect(result.explanation).to eq("Every day at 10:00 AM UTC")
  end

  it "parses spaced and uppercase meridiem variants the same as compact lowercase" do
    [ "Every day at 10 am", "Every day at 10 AM", "Every day at 10am" ].each do |input|
      result = described_class.preview(input: input)
      expect(result).to be_valid, "expected #{input.inspect} to be valid: #{result.errors}"
      expect(result.expression).to eq("FREQ=DAILY;BYHOUR=10;BYMINUTE=0;BYSECOND=0")
    end

    [ "Every Monday at 9:00 AM", "Every Monday at 9 AM", "Every Monday at 9 am" ].each do |input|
      result = described_class.preview(input: input)
      expect(result).to be_valid, "expected #{input.inspect} to be valid: #{result.errors}"
      expect(result.expression).to eq("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0;BYSECOND=0")
    end
  end

  it "parses 24-hour daily cadence text" do
    result = described_class.preview(input: "daily at 14:30")

    expect(result).to be_valid
    expect(result.expression).to eq("FREQ=DAILY;BYHOUR=14;BYMINUTE=30;BYSECOND=0")
  end

  it "does not leak raw Ruby Integer() exception text on invalid input" do
    result = described_class.preview(input: "Every day at 10 xm")

    expect(result).not_to be_valid
    expect(result.errors.join).not_to match(/invalid value for Integer/)
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
    expect(result.source).to eq("structured_intent")
    expect(result.structured_intent).to eq({ frequency: "weekly", day: "monday", hour: 9, minute: 0 })
  end

  describe "malformed structured intent (e.g. from an LLM fallback)" do
    it "fails closed with a clear error, not a raw Integer() exception, when hour is missing" do
      result = described_class.preview(input: "x", structured_intent: { frequency: "daily" })

      expect(result).not_to be_valid
      expect(result.errors.join).to include("hour is required")
      expect(result.errors.join).not_to match(/invalid value for Integer/)
    end

    it "fails closed when hour is not a number" do
      result = described_class.preview(input: "x", structured_intent: { frequency: "daily", hour: "noon" })

      expect(result).not_to be_valid
      expect(result.errors.join).to include("hour must be a whole number")
      expect(result.errors.join).not_to match(/invalid value for Integer/)
    end

    it "fails closed on an unrecognized day name" do
      result = described_class.preview(input: "x", structured_intent: { frequency: "weekly", day: "someday", hour: 9 })

      expect(result).not_to be_valid
      expect(result.errors.join).to include("day must be a day of the week")
    end

    it "fails closed on an unsupported frequency" do
      result = described_class.preview(input: "x", structured_intent: { frequency: "fortnightly", hour: 9 })

      expect(result).not_to be_valid
      expect(result.errors.join).to include("frequency must be")
    end
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

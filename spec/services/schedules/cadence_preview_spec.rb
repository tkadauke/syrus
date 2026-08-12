require "rails_helper"

RSpec.describe Schedules::CadencePreview do
  let(:user) { Factories.user }

  it "returns the deterministic result directly when it is already valid" do
    result = described_class.call(input: "0 9 * * 1", user: user)

    expect(result).to be_valid
    expect(result.source).to eq("cron")
  end

  it "does not consult the LLM when a cron-shaped expression is deterministically invalid" do
    expect(Schedules::CadenceLlmFallback).not_to receive(:call)

    result = described_class.call(input: "*/30 * * * *", user: user)

    expect(result).not_to be_valid
  end

  it "does not consult the LLM when structured_intent was already supplied" do
    expect(Schedules::CadenceLlmFallback).not_to receive(:call)

    result = described_class.call(input: "modays at 9", structured_intent: { frequency: "bogus" }, user: user)

    expect(result).not_to be_valid
  end

  it "falls back to the LLM for natural text that deterministic parsing rejects, then validates deterministically" do
    fallback_intent = { frequency: "WEEKLY", day: "monday", hour: 9, minute: 0 }
    allow(Schedules::CadenceLlmFallback).to receive(:call)
      .with("moday at 9am in tjhe mornin", user: user)
      .and_return(Schedules::CadenceLlmFallback::Result.new(usable?: true, structured_intent: fallback_intent, error: nil))

    result = described_class.call(input: "moday at 9am in tjhe mornin", user: user)

    expect(result).to be_valid
    expect(result.explanation).to eq("Every Monday at 9:00 AM UTC")
    expect(result.source).to eq("structured_intent")
    expect(result.structured_intent).to eq(fallback_intent)
  end

  it "returns the original deterministic error when the LLM fallback is unusable" do
    allow(Schedules::CadenceLlmFallback).to receive(:call)
      .and_return(Schedules::CadenceLlmFallback::Result.new(usable?: false, structured_intent: nil, error: "nope"))

    result = described_class.call(input: "moday at 9am in tjhe mornin", user: user)

    expect(result).not_to be_valid
    expect(result.errors).to include("Schedule input is not a supported cadence or five-field cron expression")
  end

  it "fails closed when the LLM produces malformed structured intent instead of saving a bogus schedule" do
    allow(Schedules::CadenceLlmFallback).to receive(:call)
      .and_return(Schedules::CadenceLlmFallback::Result.new(usable?: true, structured_intent: { frequency: "weekly" }, error: nil))

    result = described_class.call(input: "moday at 9am in tjhe mornin", user: user)

    expect(result).not_to be_valid
    expect(result.errors.join).to include("hour is required")
  end
end

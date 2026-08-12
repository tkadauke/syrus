require "rails_helper"

RSpec.describe Schedules::CadenceLlmFallback do
  let(:user) { Factories.user(gemini_api_key: "AIza-test-key") }

  def stub_client(&block)
    client = instance_double(Gemini::Client)
    allow(client).to receive(:generate_text, &block)
    described_class.client_factory = ->(_user) { client }
  end

  after { described_class.client_factory = nil }

  it "returns a usable structured intent for a confident high-quality response" do
    stub_client { { "frequency" => "weekly", "day" => "monday", "hour" => 9, "minute" => 0, "confidence" => "high", "ambiguous" => false } }

    result = described_class.call("moday at 9am in tjhe mornin", user: user)

    expect(result.usable?).to be(true)
    expect(result.structured_intent).to eq(
      frequency: "WEEKLY", day: "monday", month: nil, month_day: nil, hour: 9, minute: 0, confidence: "high", ambiguous: false
    )
  end

  it "is unusable when the model reports low confidence" do
    stub_client { { "frequency" => "weekly", "day" => "monday", "hour" => 9, "confidence" => "low", "ambiguous" => false } }

    result = described_class.call("something vague", user: user)

    expect(result.usable?).to be(false)
    expect(result.error).to be_present
  end

  it "is unusable when the model flags the request as ambiguous" do
    stub_client { { "frequency" => "weekly", "day" => "monday", "hour" => 9, "confidence" => "high", "ambiguous" => true } }

    result = described_class.call("sometime next week", user: user)

    expect(result.usable?).to be(false)
  end

  it "is unusable when the model cannot determine a frequency" do
    stub_client { { "frequency" => "unknown", "confidence" => "high", "ambiguous" => false } }

    result = described_class.call("whenever", user: user)

    expect(result.usable?).to be(false)
  end

  it "is unusable when the model omits an hour" do
    stub_client { { "frequency" => "daily", "confidence" => "high", "ambiguous" => false } }

    result = described_class.call("every day", user: user)

    expect(result.usable?).to be(false)
  end

  it "fails closed without making a request when the user has no Gemini key configured" do
    described_class.client_factory = nil
    user_without_key = Factories.user

    result = described_class.call("moday at 9am", user: user_without_key)

    expect(result.usable?).to be(false)
    expect(result.error).to match(/no ai scheduling assistant/i)
  end

  it "fails closed on blank input" do
    result = described_class.call("", user: user)

    expect(result.usable?).to be(false)
  end

  it "fails closed when the client raises a Gemini error" do
    stub_client { raise Gemini::Client::RateLimited, "busy" }

    result = described_class.call("moday at 9am", user: user)

    expect(result.usable?).to be(false)
    expect(result.error).to include("busy")
  end
end

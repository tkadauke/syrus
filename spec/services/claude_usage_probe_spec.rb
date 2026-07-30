require "rails_helper"

RSpec.describe ClaudeUsageProbe do
  it "normalizes Claude Code five-hour and weekly status-line limits" do
    user = Factories.user(claude_oauth_token: "oat-test")

    result = described_class.record_status_line_payload(user: user, payload: status_line_payload(five_hour: 81.2, seven_day: 33.3))

    expect(result.status).to eq("warning")
    expect(result.message).to eq("Claude usage has 19% remaining (5h 19%, weekly 67%).")
    expect(result.snapshot).to include(
      "source" => "claude_status_line",
      "remaining_percent" => 18.799999999999997
    )
    expect(result.snapshot.dig("five_hour", "label")).to eq("5h")
    expect(result.snapshot.dig("five_hour", "remaining_percent")).to eq(18.799999999999997)
    expect(result.snapshot.dig("seven_day", "label")).to eq("weekly")
    expect(result.snapshot.dig("seven_day", "remaining_percent")).to eq(66.7)
    expect(user.reload.claude_usage_status).to eq("warning")
  end

  it "marks zero remaining capacity as exhausted" do
    user = Factories.user(claude_oauth_token: "oat-test")

    result = described_class.record_status_line_payload(user: user, payload: status_line_payload(five_hour: 100, seven_day: 55))

    expect(result.status).to eq("exhausted")
    expect(user.reload.claude_usage_snapshot.dig("five_hour", "remaining_percent")).to eq(0.0)
  end

  it "ignores status-line payloads without rate limits" do
    user = Factories.user(claude_oauth_token: "oat-test")

    result = described_class.record_status_line_payload(user: user, payload: { "model" => "claude-sonnet" })

    expect(result.status).to eq("unsupported")
    expect(user.reload.claude_usage_status).to be_nil
  end

  def status_line_payload(five_hour:, seven_day:)
    {
      "rate_limits" => {
        "five_hour" => {
          "used_percentage" => five_hour,
          "resets_at" => "2026-07-30T20:00:00Z"
        },
        "seven_day" => {
          "used_percentage" => seven_day,
          "resets_at" => "2026-08-06T20:00:00Z"
        }
      }
    }
  end
end

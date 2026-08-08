require "rails_helper"

RSpec.describe BugReports::ContextFormatter do
  subject(:formatter) do
    Class.new do
      include BugReports::ContextFormatter
      public :format_context_markdown
    end.new
  end

  def call(context)
    formatter.format_context_markdown(context.to_json)
  end

  it "returns empty string for blank input" do
    expect(formatter.format_context_markdown(nil)).to eq("")
    expect(formatter.format_context_markdown("")).to eq("")
  end

  it "returns empty string for invalid JSON" do
    expect(formatter.format_context_markdown("{not json")).to eq("")
  end

  it "includes URL, browser, and viewport in output" do
    result = call(
      url: "https://example.com/jobs",
      user_agent: "Mozilla/5.0",
      viewport: { width: 1440, height: 900 },
      device_pixel_ratio: 2
    )

    expect(result).to include("URL: https://example.com/jobs")
    expect(result).to include("Browser: Mozilla/5.0")
    expect(result).to include("Viewport: 1440×900 @ 2x")
  end

  it "includes chat session ID when present" do
    result = call(chat_session_id: 42)
    expect(result).to include("Chat session: 42")
  end

  it "omits chat session row when absent" do
    result = call(url: "https://example.com")
    expect(result).not_to include("Chat session:")
  end

  describe "feature flags" do
    it "includes a Feature flags section with enabled and disabled states" do
      result = call(
        enabled_features: {
          "coding_mode" => true,
          "terminal" => false,
          "video_walkthroughs" => true
        }
      )

      expect(result).to include("**Feature flags**")
      expect(result).to include("- coding_mode: enabled")
      expect(result).to include("- terminal: disabled")
      expect(result).to include("- video_walkthroughs: enabled")
    end

    it "sorts features alphabetically" do
      result = call(
        enabled_features: {
          "terminal" => false,
          "agent_insights" => true,
          "coding_mode" => true
        }
      )

      positions = [ "agent_insights", "coding_mode", "terminal" ].map { |slug| result.index(slug) }
      expect(positions).to eq(positions.sort)
    end

    it "omits the Feature flags section when enabled_features is empty" do
      result = call(enabled_features: {})
      expect(result).not_to include("Feature flags")
    end

    it "omits the Feature flags section when enabled_features is absent" do
      result = call(url: "https://example.com")
      expect(result).not_to include("Feature flags")
    end

    it "omits the Feature flags section when enabled_features is not a hash" do
      result = formatter.format_context_markdown({ "enabled_features" => "oops" }.to_json)
      expect(result).not_to include("Feature flags")
    end
  end

  it "includes recent JS errors" do
    result = call(
      recent_errors: [
        { "message" => "TypeError: x is null", "source" => "app.js" }
      ]
    )

    expect(result).to include("**Recent JS errors**")
    expect(result).to include("`TypeError: x is null` (app.js)")
  end

  it "omits recent errors section when empty" do
    result = call(recent_errors: [])
    expect(result).not_to include("Recent JS errors")
  end
end

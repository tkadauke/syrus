require "rails_helper"

RSpec.describe ClaudeUsageStatusLineCapture do
  it "builds Claude settings and captures only rate limits from status-line stdin" do
    Dir.mktmpdir do |workspace|
      capture = described_class.prepare!(workspace_path: workspace)
      settings = capture.settings

      expect(settings.dig(:statusLine, :type)).to eq("command")
      command = settings.dig(:statusLine, :command)
      expect(command).to include("claude-usage-status-line.rb")

      payload = {
        "model" => "claude-sonnet",
        "rate_limits" => {
          "five_hour" => { "used_percentage" => 10, "resets_at" => "soon" }
        }
      }
      IO.popen(command, "r+") do |io|
        io.write(payload.to_json)
        io.close_write
        io.read
      end

      snapshot = JSON.parse(File.read(File.join(workspace, ".syrus", "claude-usage", "claude-usage-status-line.json")))
      expect(snapshot).to include("captured_at")
      expect(snapshot["rate_limits"]).to eq(payload["rate_limits"])
      expect(snapshot).not_to have_key("model")
    end
  end
end

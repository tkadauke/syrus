require "rails_helper"

RSpec.describe ChatHistoryTranscriptRenderer do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, title: "Transcript") }
  let(:renderer) do
    described_class.new(
      chat_session: chat,
      message_limit: 20,
      max_bytes: 20_000,
      entry_max_bytes: 4_000,
      tool_result_max_bytes: 4_000
    )
  end

  describe "#tool_result_summary" do
    it "extracts text from the canonical 'content' key" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Read",
        tool_use_id: "tu_abc",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_abc",
          "content" => [{ "type" => "text", "text" => "file contents here" }],
          "is_error" => false
        }
      )

      summary = renderer.send(:tool_result_summary, message)
      expect(summary).to include("file contents here")
      expect(summary).to include("ok")
    end

    it "falls back to the legacy 'result' key for older messages" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Bash",
        tool_use_id: "tu_def",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_def",
          "result" => "hello",
          "is_error" => false
        }
      )

      summary = renderer.send(:tool_result_summary, message)
      expect(summary).to include("hello")
    end

    it "reports error status when is_error is true" do
      message = chat.messages.create!(
        role: "tool_result",
        tool_name: "Bash",
        tool_use_id: "tu_err",
        content: {
          "type" => "tool_result",
          "tool_use_id" => "tu_err",
          "content" => [{ "type" => "text", "text" => "command not found" }],
          "is_error" => true
        }
      )

      summary = renderer.send(:tool_result_summary, message)
      expect(summary).to include("error")
    end
  end
end

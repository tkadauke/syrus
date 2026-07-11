require "rails_helper"

RSpec.describe LocalToolCall do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:daemon_session) do
    chat_session.create_local_daemon_session!(
      user: user,
      auth_token: "tok",
      connected_at: Time.current
    )
  end

  def tool_call(**attrs)
    daemon_session.tool_calls.create!({ tool_name: "read_file", arguments: { path: "README.md" } }.merge(attrs))
  end

  describe "#wait_for_result" do
    it "returns result immediately when already completed successfully" do
      call = tool_call(result: { content: "file contents" }, completed_at: Time.current)

      outcome = call.wait_for_result

      expect(outcome).to eq(result: { "content" => "file contents" })
    end

    it "returns error immediately when already completed with an error" do
      call = tool_call(error: "permission denied", completed_at: Time.current)

      outcome = call.wait_for_result

      expect(outcome).to eq(error: "permission denied")
    end

    it "polls until result is available" do
      call = tool_call
      poll_count = 0

      allow(call).to receive(:reload) do
        poll_count += 1
        call.result = { content: "hello" } if poll_count >= 2
        call.completed_at = Time.current if poll_count >= 2
      end
      allow(call).to receive(:sleep)

      outcome = call.wait_for_result

      expect(outcome).to eq(result: { "content" => "hello" })
      expect(poll_count).to be >= 2
    end

    it "returns a timeout error when the daemon does not respond" do
      call = tool_call
      stub_const("LocalToolCall::TIMEOUT", 0)
      allow(call).to receive(:sleep)

      outcome = call.wait_for_result

      expect(outcome[:error]).to match(/timed out/i)
    end
  end
end

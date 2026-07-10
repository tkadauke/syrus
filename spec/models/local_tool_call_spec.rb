require "rails_helper"

RSpec.describe LocalToolCall, type: :model do
  let(:user)    { Factories.user }
  let(:chat)    { ChatSession.create!(user: user) }
  let(:session) { LocalDaemonSession.create!(chat_session: chat, user: user) }

  def tool_call(**attrs)
    LocalToolCall.create!({
      local_daemon_session: session,
      chat_session: chat,
      tool_use_id: SecureRandom.hex(8),
      tool_name: "read_file",
      tool_input: { path: "/repo/app/main.rb" },
      state: "pending"
    }.merge(attrs))
  end

  it "broadcasts a dispatch notification after create" do
    broadcasts = []
    allow(ActionCable.server).to receive(:broadcast) { |stream, msg| broadcasts << [stream, msg] }

    call = tool_call
    expect(broadcasts).to include([
      "local_daemon_session_#{session.id}_tool_calls",
      { type: "dispatch", tool_call_id: call.id }
    ])
  end

  describe "#dispatch!" do
    it "transitions to dispatched and records dispatched_at" do
      call = tool_call
      freeze_time do
        call.dispatch!
        expect(call.state).to eq("dispatched")
        expect(call.dispatched_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe "#complete!" do
    it "transitions to completed with result" do
      call = tool_call
      call.complete!(result: [{ type: "text", text: "contents" }])
      expect(call.state).to eq("completed")
      expect(call.result).to eq([{ "type" => "text", "text" => "contents" }])
      expect(call.completed_at).not_to be_nil
    end
  end

  describe "#fail!" do
    it "transitions to failed with error message" do
      call = tool_call
      call.fail!(error: "file not found")
      expect(call.state).to eq("failed")
      expect(call.error).to eq("file not found")
      expect(call.completed_at).not_to be_nil
    end
  end

  describe "#wait_for_result" do
    it "returns result when the call completes before timeout" do
      call = tool_call
      Thread.new do
        sleep 0.05
        call.complete!(result: [{ "type" => "text", "text" => "hello" }])
      end

      result = call.wait_for_result(timeout: 2.seconds)
      expect(result).to eq([{ "type" => "text", "text" => "hello" }])
    end

    it "returns nil when the call fails before timeout" do
      call = tool_call
      Thread.new do
        sleep 0.05
        call.fail!(error: "boom")
      end

      result = call.wait_for_result(timeout: 2.seconds)
      expect(result).to be_nil
    end

    it "raises TimedOut when the call does not complete within the timeout" do
      call = tool_call
      expect {
        call.wait_for_result(timeout: 0.15.seconds)
      }.to raise_error(LocalToolCall::TimedOut)
    end
  end
end

require "rails_helper"

RSpec.describe ChatDanglingToolCallCloser do
  it "closes a dangling tool call after the latest user message" do
    user = Factories.user
    chat = ChatSession.create!(user: user)
    chat.messages.create!(role: "user", content: { "text" => "Look around" })
    chat.messages.create!(
      role: "tool_use",
      tool_name: "syrus-chat-sidecar.admin_overview",
      tool_use_id: "item_1",
      content: {
        "type" => "tool_use",
        "id" => "item_1",
        "name" => "syrus-chat-sidecar.admin_overview",
        "input" => {}
      }
    )

    expect {
      described_class.close!(chat_session: chat, reason: "operator_cancelled")
    }.to change { chat.messages.where(role: "tool_result").count }.by(1)

    result = chat.messages.find_by!(role: "tool_result", tool_use_id: "item_1")
    expect(result.tool_name).to eq("syrus-chat-sidecar.admin_overview")
    expect(result.content).to include(
      "type" => "tool_result",
      "tool_use_id" => "item_1",
      "is_error" => true
    )
    expect(result.content.dig("content", 0, "text")).to eq("Cancelled by operator before this tool returned.")
  end

  it "does not treat a same-id tool result from an older turn as answering the latest turn" do
    user = Factories.user
    chat = ChatSession.create!(user: user)
    chat.messages.create!(role: "user", content: { "text" => "Earlier turn" })
    chat.messages.create!(
      role: "tool_use",
      tool_name: "syrus-chat-sidecar.admin_overview",
      tool_use_id: "item_1",
      content: { "type" => "tool_use", "id" => "item_1", "name" => "syrus-chat-sidecar.admin_overview", "input" => {} }
    )
    chat.messages.create!(
      role: "tool_result",
      tool_name: "syrus-chat-sidecar.admin_overview",
      tool_use_id: "item_1",
      content: { "type" => "tool_result", "tool_use_id" => "item_1", "content" => "ok", "is_error" => false }
    )
    chat.messages.create!(role: "user", content: { "text" => "Latest turn" })
    chat.messages.create!(
      role: "tool_use",
      tool_name: "syrus-chat-sidecar.admin_overview",
      tool_use_id: "item_1",
      content: { "type" => "tool_use", "id" => "item_1", "name" => "syrus-chat-sidecar.admin_overview", "input" => {} }
    )

    expect {
      described_class.close!(chat_session: chat, reason: "operator_cancelled")
    }.to change { chat.messages.where(role: "tool_result").count }.by(1)
  end

  # The transcript renderer used to decide whether a cleanup row was benign by
  # matching its sentence, so a reworded constant would have flooded chat with
  # failed-looking tool cards while every test still passed. These assert the
  # machine-readable half of the contract the renderer now reads instead.
  describe "cleanup intent" do
    def dangling_chat
      user = Factories.user
      chat = ChatSession.create!(user: user)
      chat.messages.create!(role: "user", content: { "text" => "Look around" })
      chat.messages.create!(
        role: "tool_use",
        tool_name: "bash",
        tool_use_id: "item_1",
        content: { "type" => "tool_use", "id" => "item_1", "name" => "bash", "input" => {} }
      )
      chat
    end

    def close_with(reason)
      chat = dangling_chat
      described_class.close!(chat_session: chat, reason: reason)
      chat.messages.find_by!(role: "tool_result", tool_use_id: "item_1").content
    end

    it "marks an ended turn as benign bookkeeping" do
      expect(close_with("turn_ended")).to include(
        "benign_cleanup" => true,
        "cleanup_reason" => "turn_ended"
      )
    end

    it "marks an operator cancellation as benign bookkeeping" do
      expect(close_with("operator_cancelled")).to include(
        "benign_cleanup" => true,
        "cleanup_reason" => "operator_cancelled"
      )
    end

    # The reader has to see this one, so it must never be suppressed.
    it "does not mark a failed turn benign" do
      expect(close_with("turn_failed")).to include(
        "benign_cleanup" => false,
        "cleanup_reason" => "turn_failed"
      )
    end

    # The agent still has to know the tool never returned, or a resumed turn
    # would read the cleanup as a real result.
    it "keeps is_error true even when the close is benign" do
      expect(close_with("turn_ended")).to include("is_error" => true)
    end

    it "owns the wording for every reason rather than taking it from callers" do
      expect(close_with("turn_ended")["content"]).to eq(
        [ { "type" => "text", "text" => "Agent turn ended before this tool returned." } ]
      )
    end

    # A typo used to mean a sentence nothing suppressed, discovered only by
    # looking at a transcript. Now it cannot leave the process.
    it "refuses a reason it does not know" do
      expect { described_class.close!(chat_session: dangling_chat, reason: "nonsense") }
        .to raise_error(ArgumentError, /unknown dangling tool call reason/)
    end
  end
end

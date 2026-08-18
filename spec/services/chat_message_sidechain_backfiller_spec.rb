require "rails_helper"

RSpec.describe ChatMessageSidechainBackfiller do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }

  def tool_use_message(tool_use_id, name: "Read")
    chat.messages.create!(
      role: "tool_use",
      tool_name: name,
      tool_use_id: tool_use_id,
      content: { "type" => "tool_use", "id" => tool_use_id, "name" => name, "input" => {} }
    )
  end

  def tool_result_message(tool_use_id)
    chat.messages.create!(
      role: "tool_result",
      tool_use_id: tool_use_id,
      content: { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "ok", "is_error" => false }
    )
  end

  it "tags the matching tool_use/tool_result rows with sidechain + parent_tool_use_id" do
    outer = tool_use_message("toolu_agent1", name: "Agent")
    nested_use = tool_use_message("sub_read1")
    nested_result = tool_result_message("sub_read1")

    described_class.call(
      chat_session: chat,
      normalized_messages: [
        { "role" => "tool_use", "content" => { id: "toolu_agent1", name: "Agent" } },
        { "role" => "tool_use", "content" => { id: "sub_read1", name: "Read" },
          "sidechain" => true, "parent_tool_use_id" => "toolu_agent1" },
        { "role" => "tool_result", "content" => { tool_use_id: "sub_read1" },
          "sidechain" => true, "parent_tool_use_id" => "toolu_agent1" }
      ]
    )

    expect(outer.reload).to have_attributes(sidechain: false, parent_tool_use_id: nil)
    expect(nested_use.reload).to have_attributes(sidechain: true, parent_tool_use_id: "toolu_agent1")
    expect(nested_result.reload).to have_attributes(sidechain: true, parent_tool_use_id: "toolu_agent1")
  end

  it "matches tool_result rows via a string 'tool_use_id' content key" do
    nested_result = tool_result_message("sub_read2")

    described_class.call(
      chat_session: chat,
      normalized_messages: [
        { "role" => "tool_result", "content" => { "tool_use_id" => "sub_read2" },
          "sidechain" => true, "parent_tool_use_id" => "toolu_agent2" }
      ]
    )

    expect(nested_result.reload).to have_attributes(sidechain: true, parent_tool_use_id: "toolu_agent2")
  end

  it "ignores non-sidechain and non-tool normalized messages" do
    message = tool_use_message("toolu_x")

    described_class.call(
      chat_session: chat,
      normalized_messages: [
        { "role" => "user", "content" => "hi" },
        { "role" => "tool_use", "content" => { id: "toolu_x" } }
      ]
    )

    expect(message.reload).to have_attributes(sidechain: false, parent_tool_use_id: nil)
  end

  it "does nothing for an empty or nil normalized_messages list" do
    message = tool_use_message("toolu_y")

    expect { described_class.call(chat_session: chat, normalized_messages: nil) }.not_to raise_error
    expect { described_class.call(chat_session: chat, normalized_messages: []) }.not_to raise_error
    expect(message.reload).to have_attributes(sidechain: false, parent_tool_use_id: nil)
  end

  it "only matches rows scoped to the given chat session" do
    other_chat = ChatSession.create!(user: user)
    other_message = other_chat.messages.create!(
      role: "tool_use", tool_use_id: "shared_id",
      content: { "type" => "tool_use", "id" => "shared_id", "name" => "Read", "input" => {} }
    )

    described_class.call(
      chat_session: chat,
      normalized_messages: [
        { "role" => "tool_use", "content" => { id: "shared_id" },
          "sidechain" => true, "parent_tool_use_id" => "toolu_agent3" }
      ]
    )

    expect(other_message.reload).to have_attributes(sidechain: false, parent_tool_use_id: nil)
  end
end

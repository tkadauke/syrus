require "rails_helper"

RSpec.describe Coworkers::ChatToolSet do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "advertises messaging, owner-thread replies, scheduling, and workspace tools only on the essential coworker surface" do
    expect(Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set)).to include(described_class)
    expect(described_class.available_for?(chat, tier: :essential)).to be(false)
    expect(described_class.available_for_coworker?(chat, tier: :essential)).to be(true)
    expect(described_class.available_for_coworker?(chat, tier: :deferred)).to be(false)

    expect(described_class.tool_definitions(tier: :deferred).pluck(:name)).to include(
      "list_coworkers", "read_coworker", "propose_coworker", "propose_coworker_grants"
    )

    definitions = described_class.tool_definitions(tier: :essential)
    expect(definitions).to include(
      include(name: "message_coworker", coworker_safe: true, capability: "coworker.message", mutation: true),
      include(name: "reply_in_chat_thread", coworker_safe: true, capability: "chat.reply_owner_thread", coworker_grantless: true, mutation: true),
      include(name: "manage_coworker_schedule", coworker_safe: true, capability: "schedule.manage_self", mutation: true),
      include(name: "write_coworker_file", coworker_safe: true, capability: "workspace.files", coworker_grantless: true, mutation: true),
      include(name: "edit_coworker_file", coworker_safe: true, capability: "workspace.files", mutation: true),
      include(name: "move_coworker_file", coworker_safe: true, capability: "workspace.files", mutation: true),
      include(name: "delete_coworker_file", coworker_safe: true, capability: "workspace.files", mutation: true)
    )
    expect(described_class.tool_definitions(tier: :deferred).pluck(:name)).not_to include("message_coworker")
  end

  it "dispatches reply_in_chat_thread through the reply-only tool" do
    allow(Coworkers::ReplyInChatThreadTool).to receive(:call).and_return(:response)

    result = described_class.new.handle("reply_in_chat_thread", { "thread_id" => 12, "text" => "Done" }, { chat_session: chat })

    expect(result).to eq(:response)
    expect(Coworkers::ReplyInChatThreadTool).to have_received(:call).with(
      thread_id: 12, text: "Done", server_context: { chat_session: chat }
    )
  end

  it "dispatches workspace operations through the plugin-owned tools" do
    allow(Coworkers::WorkspaceFileTools::Write).to receive(:call).and_return(:response)

    result = described_class.new.handle("write_coworker_file", { "path" => "SOUL.md", "content" => "updated" }, { chat_session: chat })

    expect(result).to eq(:response)
    expect(Coworkers::WorkspaceFileTools::Write).to have_received(:call).with(
      path: "SOUL.md", content: "updated", server_context: { chat_session: chat }
    )
  end

  it "dispatches message_coworker through the plugin-owned tool" do
    allow(Coworkers::MessageCoworkerTool).to receive(:call).and_return(:response)

    result = described_class.new.handle("message_coworker", { "handle" => "rin", "text" => "Hello" }, { chat_session: chat })

    expect(result).to eq(:response)
    expect(Coworkers::MessageCoworkerTool).to have_received(:call).with(
      handle: "rin", text: "Hello", server_context: { chat_session: chat }
    )
  end
end

require "rails_helper"

RSpec.describe AdminMysql::ChatToolSet do
  let(:admin_chat) { instance_double(ChatSession, user: instance_double(User, admin?: true)) }
  let(:regular_chat) { instance_double(ChatSession, user: instance_double(User, admin?: false)) }

  it "is unavailable outside MySQL even for admins" do
    allow(AdminMysql).to receive(:mysql?).and_return(false)

    expect(described_class.available_for?(admin_chat, tier: :essential)).to be(false)
  end

  it "is unavailable for non-admin chats" do
    allow(AdminMysql).to receive(:mysql?).and_return(true)

    expect(described_class.available_for?(regular_chat, tier: :essential)).to be(false)
  end

  it "exposes live status and kill-query MCP commands" do
    tools = described_class.tool_definitions(tier: :essential)

    expect(tools.map { |tool| tool.fetch(:name) }).to contain_exactly(
      "admin_mysql_status",
      "admin_mysql_kill_query"
    )
    expect(tools.find { |tool| tool.fetch(:name) == "admin_mysql_kill_query" }.dig(:input_schema, :required)).to eq([ "thread_id" ])
  end
end

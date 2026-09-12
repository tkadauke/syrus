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

  it "keeps admin chat kill-query dispatch intact" do
    payload = { killed: true, thread_id: 42 }
    inspector = instance_double(AdminMysql::Inspector, kill_query: payload)
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)

    response = described_class.new.handle("admin_mysql_kill_query", { "thread_id" => 42 }, { chat_session: admin_chat })

    expect(response.error?).to be(false)
    expect(response.content.first[:text]).to eq(JSON.pretty_generate(payload))
    expect(inspector).to have_received(:kill_query).with(42)
  end

  it "refuses kill-query dispatch outside an admin chat context" do
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.new.handle("admin_mysql_kill_query", { "thread_id" => 42 }, { run_id: 1 })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unauthorized")
  end

  it "refuses direct kill-query dispatch from non-admin chats" do
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.new.handle("admin_mysql_kill_query", { "thread_id" => 42 }, { chat_session: regular_chat })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unauthorized")
  end
end

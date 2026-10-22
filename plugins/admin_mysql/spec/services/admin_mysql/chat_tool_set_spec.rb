require "rails_helper"

RSpec.describe AdminMysql::ChatToolSet do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_chat) { ChatSession.create!(user: admin) }
  let(:regular_chat) do
    instance_double(
      ChatSession,
      user: instance_double(User, admin?: false),
      coding?: false,
      mode: "planner",
      repository: nil,
      attached_repositories: double(ids: [])
    )
  end

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

  it "creates a pending action with the current statement instead of killing immediately" do
    inspector = instance_double(AdminMysql::Inspector, process: {
      id: 42,
      info: "SELECT * FROM jobs WHERE token = ?",
      user: "syrus",
      host: "worker:3306",
      database: "syrus_production",
      time_seconds: 12,
      state: "executing",
      statement_digest: "safe-digest"
    })
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)

    response = described_class.new.handle("admin_mysql_kill_query", { "thread_id" => 42 }, { chat_session: admin_chat })

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text])
    action = admin_chat.pending_actions.find(payload.fetch("pending_action_id"))
    expect(action).to have_attributes(
      action: "admin_mysql_kill_query",
      state: "pending",
      user: admin,
      payload: {
        "thread_id" => 42,
        "statement" => "SELECT * FROM jobs WHERE token = ?",
        "user" => "syrus",
        "host" => "worker:3306",
        "database" => "syrus_production",
        "time_seconds" => 12,
        "query_state" => "executing",
        "statement_digest" => "safe-digest"
      }
    )
    expect(payload).to include(
      "thread_id" => 42,
      "statement" => "SELECT * FROM jobs WHERE token = ?",
      "user" => "syrus",
      "host" => "worker:3306",
      "database" => "syrus_production",
      "time_seconds" => 12,
      "query_state" => "executing"
    )
    expect(response.content.first[:text]).not_to include("top-secret")
    expect(inspector).to have_received(:process).with(42)
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

  it "refuses direct status dispatch from non-admin chats" do
    expect(AdminMysql::Inspector).not_to receive(:new)

    response = described_class.new.handle("admin_mysql_status", {}, { chat_session: regular_chat })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unauthorized")
  end
end

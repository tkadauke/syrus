require "rails_helper"

RSpec.describe SyrusChatMcp::ScheduleRecurringTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc(server, "tools/call", params: { name: "schedule_recurring", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates a pending confirmation instead of a ScheduledTask" do
    response = nil
    expect {
      response = call_tool(
        cron_expression: "0 9 * * *",
        label: "Daily review",
        prompt: "Review the repository."
      )
    }.not_to change { ScheduledTask.count }

    expect(response[:result][:isError]).to be_falsey
    payload = response_payload(response)
    action = ChatPendingAction.find(payload.fetch(:pending_confirmation_id))
    expect(action).to have_attributes(
      chat_session: chat_session,
      repository: repository,
      user: user,
      action_type: "schedule_recurring",
      state: "pending"
    )
    expect(action.payload).to include(
      "cron_expression" => "0 9 * * *",
      "label" => "Daily review",
      "prompt" => "Review the repository."
    )
  end

  it "describes the scheduled prompt as cron work rather than an ad hoc Job" do
    schema = described_class.input_schema.instance_variable_get(:@schema)
    prompt_description = schema.fetch(:properties).fetch(:prompt).fetch(:description)

    expect(prompt_description).to include("scheduled cron Job")
    expect(prompt_description).not_to include("ad hoc")
  end

  it "describes cron minutes as honored" do
    schema = described_class.input_schema.instance_variable_get(:@schema)
    cron_description = schema.fetch(:properties).fetch(:cron_expression).fetch(:description)

    expect(cron_description).to include("minute field is honored")
    expect(cron_description).not_to include("minute field is ignored")
  end

  it "returns a tool error for an invalid cron expression" do
    response = call_tool(
      cron_expression: "not cron",
      label: "Broken",
      prompt: "This should not persist."
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/cron|Cron/i)
    expect(ChatPendingAction.count).to eq(0)
  end
end

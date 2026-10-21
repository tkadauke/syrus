require "rails_helper"

RSpec.describe Mcp::Tools::OverrideJobPlannedExecutionTool do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:chat_session) { ChatSession.create!(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "backlog", planned_execution_capabilities: ExecutionPlacementProfile.fetch("ios_xcode").capabilities, planned_execution_source: "classifier") }

  def call_tool(arguments)
    server = MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "override_job_planned_execution", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response) = JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)

  it "returns a complete dry-run without mutation" do
    before = job.planned_execution_json
    result = payload(call_tool(job_id: job.id, profile: "linux", reason: "Correct placement", dry_run: true))

    expect(result).to include(dry_run: true, eligible: true, profile: "linux", current_placement: symbolize_keys(before))
    expect(result[:proposed_placement][:capabilities]).to eq(os: [ "linux" ])
    expect(job.reload.planned_execution_json).to eq(before)
    expect(ChatPendingAction.count).to eq(0)
  end

  it "stays pending until confirmation and records chat provenance" do
    result = payload(call_tool(job_id: job.id, profile: "linux", reason: "Correct placement"))
    action = ChatPendingAction.find(result.fetch(:pending_action_id))

    expect(action).to be_pending
    expect(job.reload.planned_execution_capabilities).to eq(ExecutionPlacementProfile.fetch("ios_xcode").capabilities)
    action.confirm!(user: admin)
    expect(job.reload.planned_execution_capabilities).to eq("os" => [ "linux" ])
    expect(job.planned_execution_overrides.sole.provenance).to eq("syrus_chat")
  end

  it "refuses a confirmation race without partial placement changes" do
    result = payload(call_tool(job_id: job.id, profile: "linux", reason: "Correct placement"))
    action = ChatPendingAction.find(result.fetch(:pending_action_id))
    before = job.planned_execution_json
    job.update!(priority: "high")

    expect { action.confirm!(user: admin) }.to raise_error(PlannedExecutionOverrides::Operation::Unsafe)
    expect(job.reload.planned_execution_json).to eq(before)
    expect(job.planned_execution_overrides).to be_empty
  end

  def symbolize_keys(value)
    value.deep_symbolize_keys
  end
end

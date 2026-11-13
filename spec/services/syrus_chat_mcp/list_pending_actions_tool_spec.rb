require "rails_helper"

RSpec.describe Mcp::Tools::ListPendingActionsTool, :full_chat_access do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def call_tool(arguments = {})
    server = MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_pending_actions", arguments: arguments } }.to_json)
    response = JSON.parse(raw, symbolize_names: true)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def action(session: chat_session, state: "pending", payload: {}, **attributes)
    record = session.pending_actions.create!(action: "pause_landing_queue", payload: {})
    record.update_columns({ state: state, payload: payload, updated_at: Time.current }.merge(attributes))
    record.reload
  end

  it "lists only pending actions from the current chat by default with compact targets" do
    pending = action(payload: { "job_id" => 12, "workflow_id" => 34, "secret" => "do not expose" }, reason: "CI needs another pass")
    action(state: "confirmed", confirmed_at: Time.current)
    action(session: ChatSession.create!(user: user))
    action(session: ChatSession.create!(user: Factories.user))

    result = call_tool

    expect(result).to include(count: 1, state: "pending", limit: 20)
    expect(result.fetch(:actions)).to contain_exactly(hash_including(
      pending_action_id: pending.id,
      action: "pause_landing_queue",
      target_ids: { job_id: 12, workflow_id: 34 },
      reason: "CI needs another pass",
      state: "pending"
    ))
    expect(result.to_s).not_to include("do not expose")
  end

  it "filters resolved states and jobs, including grouped job_ids" do
    matching = action(state: "confirmed", payload: { "job_ids" => [ 8, 9 ] }, confirmed_at: 1.minute.ago)
    action(state: "confirmed", payload: { "job_id" => 10 }, confirmed_at: Time.current)
    action(payload: { "job_id" => 8 })

    result = call_tool(state: "confirmed", job_id: 8)

    expect(result.fetch(:actions).map { |row| row.fetch(:pending_action_id) }).to eq([ matching.id ])
    expect(result.fetch(:actions).first).to include(resolved_at: matching.confirmed_at.iso8601)
  end

  it "includes grouped and failed action details" do
    group = PendingActionGroup.create_with_members!(
      chat_session: chat_session,
      member_attributes: [ { action: "pause_landing_queue", payload: {} } ]
    )
    failed = group.chat_pending_actions.first
    failed.update_columns(
      state: "failed",
      payload: { "job_id" => 7 },
      execution_status: "failed",
      execution_error: "ChatPendingAction::ConfirmationStalled: confirmation timed out",
      execution_finished_at: Time.current,
      updated_at: Time.current
    )
    failed.reload

    row = call_tool(state: "failed").fetch(:actions).first

    expect(row).to include(
      pending_action_id: failed.id,
      group_id: group.id,
      execution_status: "failed",
      error_summary: include("ConfirmationStalled"),
      resolved_at: failed.execution_finished_at.iso8601
    )
  end

  it "redacts credentials from operator-facing and failure summaries" do
    action(
      state: "failed",
      reason: "Retry https://x-access-token:operator-secret@github.com/acme/widgets.git",
      execution_error: "Command failed with github_token=ghp_abcdefghijklmnopqrstuvwxyz123456",
      execution_finished_at: Time.current
    )

    row = call_tool(state: "failed").fetch(:actions).first

    expect(row.fetch(:reason)).to include("[redacted]")
    expect(row.fetch(:error_summary)).to include("[redacted]")
    expect(row.to_s).not_to include("operator-secret", "ghp_abcdefghijklmnopqrstuvwxyz123456")
  end

  it "caps the requested limit at 100" do
    101.times { |index| action(payload: { "job_id" => index + 1 }) }

    result = call_tool(state: "all", limit: 500)

    expect(result).to include(count: 100, limit: 100)
    expect(result.fetch(:actions).length).to eq(100)
  end
end

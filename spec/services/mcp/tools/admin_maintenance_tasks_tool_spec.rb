require "rails_helper"

RSpec.describe Mcp::Tools::AdminMaintenanceTasksTool do
  include ActiveJob::TestHelper

  let(:admin) { Factories.user(admin: true, email_address: "admin-maintenance@example.test") }
  let(:repository) { Factories.repository(user: admin) }
  let(:chat_session) { ChatSession.create!(user: admin, repository: repository) }
  let(:definition) do
    instance_double(
      MaintenanceTasks::Definitions::AgentsBackfill,
      estimate_total_units: 3,
      batch_size: 1_000,
      max_parallelism: 1
    )
  end

  before do
    clear_enqueued_jobs
    allow(ChatProviders).to receive(:provider_keys).and_return([ "claude" ])
    allow(MaintenanceTasks::Registry).to receive(:fetch).with("agents_backfill").and_return(definition)
  end

  after { clear_enqueued_jobs }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "admin_maintenance_tasks", arguments: arguments } }.to_json
    )
    JSON.parse(raw, symbolize_names: true)
  end

  def payload_for(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def maintenance_task(state:)
    MaintenanceTask.create!(
      definition_key: "agents_backfill",
      task_key: "spec:admin_maintenance_tasks_tool:#{SecureRandom.hex(4)}",
      state: state,
      recurrence: "one_off",
      category: "backfill",
      title: "Backfill agent records",
      summary: "Backfill missing Agent rows.",
      trigger_kind: "spec",
      trigger_key: "admin_maintenance_tasks_tool",
      required_role: "admin",
      total_units: 3
    )
  end

  {
    start: "pending",
    pause: "running",
    resume: "paused",
    cancel: "running",
    dismiss: "pending"
  }.each do |action, initial_state|
    it "creates a pending confirmation for #{action} without executing immediately" do
      task = maintenance_task(state: initial_state)
      chat_session
      clear_enqueued_jobs

      expect {
        response = call_tool(action: action.to_s, task_id: task.id)
        body = payload_for(response)
        pending_action = ChatPendingAction.find(body.fetch(:pending_confirmation_id))

        expect(response.dig(:result, :isError)).to be_falsey
        expect(body).to include(state: "pending", message: a_string_matching(/\?/))
        expect(pending_action).to have_attributes(
          chat_session: chat_session,
          user: admin,
          repository: repository,
          action: "admin_maintenance_task",
          requested_by: "agent"
        )
        expect(pending_action.payload).to include("task_id" => task.id, "task_action" => action.to_s)
      }.to change(ChatPendingAction, :count).by(1)

      expect(task.reload.state).to eq(initial_state)
      expect(enqueued_jobs.pluck(:job)).not_to include(MaintenanceTaskRunJob)
    end
  end

  it "executes the stored maintenance action only when the pending action is confirmed" do
    task = maintenance_task(state: "pending")
    pending_action = chat_session.pending_actions.create!(
      action: "admin_maintenance_task",
      payload: { "task_id" => task.id, "task_action" => "start" },
      requested_by: "agent"
    )

    expect {
      PendingActions::AdminMaintenanceTask.new(pending_action).execute
    }.to have_enqueued_job(MaintenanceTaskRunJob).with(task.id)

    expect(task.reload.state).to eq("running")
    expect(task.requested_by_user).to eq(admin)
  end
end

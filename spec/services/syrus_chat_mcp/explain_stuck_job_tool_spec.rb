require "rails_helper"


RSpec.describe Mcp::Tools::ExplainStuckJobTool do
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

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "explain_stuck_job", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns a structured diagnosis for an accessible Job" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented", issue_title: "Needs diagnosis")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload[:job]).to include(id: job.id, state: "implemented", issue_title: "Needs diagnosis")
    expect(payload).to include(:workflows, :runs, :dependencies, :landing, :empty_reconciliation, :recommended_action, :human_summary)
  end

  it "explains one stuck Job from reconciler issues and repair plans" do
    job = Factories.job(user: user, repository: repository, issue_title: "Silent run")
    run = job.initial_run
    workflow = run.step.workflow
    stale_at = (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
    workflow.update_columns(state: "running", started_at: stale_at)
    run.update_columns(state: "running", started_at: stale_at, last_heartbeat_at: stale_at)

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload).to include(stuck: true)
    expect(payload.fetch(:stuck_list)).to include(listed: true)
    expect(payload.fetch(:job)).to include(id: job.id, title: "Silent run", issue_title: "Silent run", state: job.reload.state)
    expect(payload.dig(:stuck_list, :items)).to include(hash_including(
      kind: "running_run_without_live_worker_evidence",
      workflow_id: workflow.id,
      run_id: run.id
    ))
    expect(payload.fetch(:issues).first).to include(
      kind: "running_run_without_live_worker_evidence",
      attention_state: "auto_repairable",
      workflow_id: workflow.id,
      run_id: run.id
    )
    expect(payload.fetch(:issues).first.fetch(:repair_plan)).to include(
      action: "mark_worker_died",
      auto_executable: true
    )
  end

  it "is exposed through the deferred sidecar" do
    expect(Mcp::Sidecar::CHAT_DEFERRED_TOOLS).to include(described_class)
    expect(Mcp::Sidecar.chat_tool_names(chat_session, tier: :deferred)).to include("explain_stuck_job")
  end
end

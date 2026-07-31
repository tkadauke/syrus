require "rails_helper"

RSpec.describe SyrusChatMcp::ExplainStuckJobTool do
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

  it "is exposed through the deferred sidecar" do
    expect(SyrusChatMcp::DeferredSidecar::DEFERRED_TOOLS).to include(described_class)
    expect(SyrusChatMcp::DeferredSidecar.tool_names(chat_session)).to include("explain_stuck_job")
  end
end

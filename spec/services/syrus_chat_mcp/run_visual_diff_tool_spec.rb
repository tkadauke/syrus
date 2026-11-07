require "rails_helper"

RSpec.describe Mcp::Tools::RunVisualDiffTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def call_tool(arguments)
    server = MCP::Server.new(name: "syrus-chat-sidecar", tools: [ described_class ], server_context: { chat_session: chat_session })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "run_visual_diff", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "creates an operator-confirmed pending action without queueing a workflow" do
    job = Factories.job_record(repository: repository, state: "implemented")

    expect { @response = call_tool(job_id: job.id) }.not_to have_enqueued_job(RunJob)

    action = chat_session.pending_actions.find(payload(@response)[:pending_confirmation_id])
    expect(action).to have_attributes(action: "run_visual_diff", state: "pending", requested_by: "agent")
    expect(action.payload).to eq("job_id" => job.id)
    expect(payload(@response)[:message]).to include("before/after visual comparison")
    expect(job.workflows.where(trigger_kind: "visual_diff")).to be_empty
  end

  it "uses the requesting user's repository access" do
    other_user = Factories.user
    other_job = Factories.job_record(user: other_user, repository: Factories.repository(user: other_user), state: "implemented")

    response = call_tool(job_id: other_job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("job not found")
    expect(chat_session.pending_actions).to be_empty
  end

  it "creates no workflow when the operator rejects the request" do
    job = Factories.job_record(repository: repository, state: "implemented")
    action = chat_session.pending_actions.find(payload(call_tool(job_id: job.id))[:pending_confirmation_id])

    action.reject!(user: user)

    expect(action.reload).to be_rejected
    expect(job.workflows.where(trigger_kind: "visual_diff")).to be_empty
  end
end

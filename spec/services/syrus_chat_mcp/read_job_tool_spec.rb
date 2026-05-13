require "rails_helper"

RSpec.describe SyrusChatMcp::ReadJobTool do
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
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_job", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "returns metadata, latest workflow summary, and transcript head/tail" do
    job = Factories.job(repository: repository, issue_number: 123, issue_title: "Fix the aqueduct", branch_name: "syrus/issue-123", pr_number: 9)
    workflow = job.latest_workflow
    workflow.set_artifact!("summary", "Raised the aqueduct by one cubit.")
    run = workflow.first_step.latest_run
    run.job_logs.create!(sequence: 0, kind: "stdout", chunk: "head-" + ("a" * 9.kilobytes))
    run.job_logs.create!(sequence: 1, kind: "stdout", chunk: "tail")

    response = call_tool(job_id: job.id)
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload[:job]).to include(id: job.id, issue_number: 123, pr_number: 9, branch_name: "syrus/issue-123", agent_provider: "claude")
    expect(payload[:latest_workflow]).to include(id: workflow.id, trigger_kind: "initial", summary: "Raised the aqueduct by one cubit.")
    expect(payload[:transcript]).to include(truncated: true)
    expect(payload[:transcript][:head]).to start_with("head-")
    expect(payload[:transcript][:tail]).to include("tail")
  end

  it "returns a tool error when the job is outside the chat repository" do
    other = Factories.job(repository: Factories.repository(user: user))

    response = call_tool(job_id: other.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("job not found")
  end
end

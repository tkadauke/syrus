require "rails_helper"

RSpec.describe "SyrusChatMcp job control tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::CancelJobTool,
        SyrusChatMcp::RetryJobTool,
        SyrusChatMcp::RebaseJobTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "creates a pending cancel_job confirmation without executing it" do
    job = Factories.job(repository: repository)

    response = call_tool("cancel_job", job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action).to have_attributes(action: "cancel_job", requested_by: "agent")
    expect(pending_action.payload).to eq("job_id" => job.id)
    expect(job.reload).to be_open
  end

  it "creates a pending retry_job confirmation without executing it" do
    job = Factories.job(repository: repository)

    response = call_tool("retry_job", job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action.action).to eq("retry_job")
    expect(job.workflows.where(trigger_kind: "retry")).to be_empty
  end

  it "creates a pending rebase_job confirmation without executing it" do
    job = Factories.job(repository: repository, pr_number: 12)

    response = call_tool("rebase_job", job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action.action).to eq("rebase_job")
    expect(job.workflows.where(trigger_kind: "rebase")).to be_empty
  end

  it "rejects jobs outside the chat repository" do
    other_job = Factories.job(repository: Factories.repository(user: user))

    response = call_tool("cancel_job", job_id: other_job.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("job not found in this repository")
    expect(chat_session.pending_actions).to be_empty
  end
end

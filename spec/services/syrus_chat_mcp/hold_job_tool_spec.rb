require "rails_helper"

RSpec.describe "Mcp::Tools::HoldJobTool" do
  before(:all) { ensure_solid_queue_test_tables! }
  after(:all) { drop_solid_queue_test_tables! }
  before { clear_solid_queue_test_tables! }

  let(:admin) { Factories.user(admin: true, email_address: "admin@example.com") }
  let(:member) { Factories.user(email_address: "member@example.com") }
  let(:repository) { Factories.repository(user: admin) }
  let(:admin_session) { ChatSession.create!(user: admin, repository: repository) }
  let(:job) { Factories.job_record(state: "running", repository: repository, user: admin, pr_number: 77) }
  let(:prerequisite) { Factories.job_record(state: "running", repository: repository, user: admin, issue_number: 900) }

  def call_tool(chat_session, arguments)
    grant_full_chat_access(chat_session.user)
    server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ Mcp::Tools::HoldJobTool ],
      server_context: { chat_session: chat_session }
    )
    raw = server.handle_json(
      { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "hold_job", arguments: arguments } }.to_json
    )
    JSON.parse(raw, symbolize_names: true)
  end

  def text(response)
    response.dig(:result, :content, 0, :text)
  end

  def make_holdable
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "running")
    attach_work_unit(workflow, state: "running")
    Run.create!(job: job, user: admin, trigger_kind: "initial", agent_provider: "claude", state: "running")
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
  end

  it "creates a pending action with the reason for a holdable Job" do
    make_holdable

    response = call_tool(admin_session, job_id: job.id, reason: "ahead of its turn")
    body = JSON.parse(text(response), symbolize_names: true)
    action = ChatPendingAction.find(body.fetch(:pending_action_id))

    expect(response.dig(:result, :isError)).to be_falsey
    expect(action).to have_attributes(action: "hold_job", reason: "ahead of its turn", state: "pending")
    expect(action.payload).to eq("job_id" => job.id, "to_backlog" => false)
    expect(job.reload.state).to eq("running")
  end

  it "requires a reason" do
    make_holdable

    response = call_tool(admin_session, job_id: job.id, reason: "  ")

    expect(response.dig(:result, :isError)).to be true
    expect(text(response)).to include("reason is required")
    expect(ChatPendingAction.where(action: "hold_job")).to be_empty
  end

  it "reports an unknown Job" do
    response = call_tool(admin_session, job_id: 0, reason: "x")

    expect(response.dig(:result, :isError)).to be true
    expect(text(response)).to include("job not found")
  end

  it "refuses a Job with no active work without creating a pending action" do
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

    response = call_tool(admin_session, job_id: job.id, reason: "x")

    expect(response.dig(:result, :isError)).to be true
    expect(ChatPendingAction.where(action: "hold_job")).to be_empty
  end

  it "refuses non-admin chat sessions" do
    make_holdable
    session = ChatSession.create!(user: member, repository: Factories.repository(user: member))

    response = call_tool(session, job_id: job.id, reason: "x")

    expect(response.dig(:result, :isError)).to be true
    expect(ChatPendingAction.where(action: "hold_job")).to be_empty
  end
end

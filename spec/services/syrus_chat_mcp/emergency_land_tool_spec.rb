require "rails_helper"

RSpec.describe Mcp::Tools::EmergencyLandTool do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository, mode: "coding") }

  before do
    Feature.find_or_create_by!(slug: "emergency_land") { |f| f.category = "Labs"; f.name = "Emergency land" }
           .update!(enabled: true)
  end

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(**arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "emergency_land", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "creates a pending emergency land confirmation without landing immediately" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident", pr_number: nil)
    allow(EmergencyLand::Lander).to receive(:land)

    response = call_tool(job_id: job.id)
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(result[:message]).to include("requires operator confirmation")
    pending_action = ChatPendingAction.find(result[:pending_action_id])
    expect(pending_action).to have_attributes(action: "emergency_land", requested_by: "agent")
    expect(pending_action.payload).to include(
      "chat_session_id" => chat_session.id,
      "job_id" => job.id,
      "branch_name" => "syrus/incident"
    )
    expect(EmergencyLand::Lander).not_to have_received(:land)
  end

  it "stores a supplied branch_name on the pending action instead of mutating the Job immediately" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/stale", pr_number: nil)

    response = call_tool(job_id: job.id, branch_name: "syrus/pushed-incident-fix")
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    pending_action = ChatPendingAction.find(result[:pending_action_id])
    expect(pending_action.payload["branch_name"]).to eq("syrus/pushed-incident-fix")
    expect(job.reload.branch_name).to eq("syrus/stale")
  end

  it "rejects when a normal handoff confirmation is already pending for the same Job" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident", pr_number: nil)
    chat_session.pending_actions.create!(
      action: "complete_implement_step",
      payload: { "job_id" => job.id },
      requested_by: "agent"
    )

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("complete_implement_step confirmation is already pending")
    expect(chat_session.pending_actions.where(action: "emergency_land").count).to eq(0)
  end

  it "reuses an existing pending emergency land confirmation for the same Job" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident", pr_number: nil)
    existing = chat_session.pending_actions.create!(
      action: "emergency_land",
      payload: { "chat_session_id" => chat_session.id, "job_id" => job.id, "branch_name" => "syrus/incident" },
      requested_by: "agent"
    )

    response = call_tool(job_id: job.id)
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(result[:pending_action_id]).to eq(existing.id)
    expect(chat_session.pending_actions.where(action: "emergency_land").count).to eq(1)
  end

  it "rejects when the emergency land feature flag is off" do
    Feature.find_by!(slug: "emergency_land").update!(enabled: false)
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not enabled")
  end

  it "rejects outside Coding Mode chat sessions" do
    chat_session.update!(mode: "planning")
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("Coding Mode")
  end

  it "rejects a caller without repository admin permission" do
    outsider = Factories.user
    chat_session.update!(user: outsider)
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("admin permissions")
  end

  it "allows an admin-tier repository member who is not the Job owner" do
    admin_member = Factories.user
    RepositoryMembership.create!(repository: repository, user: admin_member, role: "admin")
    chat_session.update!(user: admin_member)
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")

    response = call_tool(job_id: job.id)
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(ChatPendingAction.find(result[:pending_action_id]).action).to eq("emergency_land")
  end

  it "rejects a Job without a recorded or supplied pushed branch" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: nil, pr_number: nil)

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("branch_name is required")
  end
end

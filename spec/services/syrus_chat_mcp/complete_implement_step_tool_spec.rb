require "rails_helper"

RSpec.describe SyrusChatMcp::CompleteImplementStepTool do
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

  def call_tool(**arguments)
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "complete_implement_step", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "creates a pending confirmation for a job attached to the chat session" do
    job = Factories.job_record(repository: repository, state: "open")
    chat_session.chat_attachments.create!(attachable: job)

    response = call_tool(job_id: job.id)
    body = payload(response)
    pending_action = chat_session.pending_actions.find(body[:pending_action_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body).to include(state: "pending")
    expect(body[:message]).to include("pending operator confirmation")
    expect(pending_action).to have_attributes(
      action: "complete_implement_step",
      state: "pending",
      requested_by: "agent"
    )
    expect(pending_action.payload).to eq("job_id" => job.id)
  end

  it "creates a pending confirmation for a job in the chat repository (not directly attached)" do
    job = Factories.job_record(repository: repository, state: "open")

    response = call_tool(job_id: job.id)
    body = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(body[:pending_action_id]).to be_present
  end

  it "rejects an unknown job_id" do
    response = call_tool(job_id: 999_999_999)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not found")
  end

  it "dispatches a coding_handoff workflow on confirmation" do
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id)
    chat_session.chat_attachments.create!(attachable: job)
    response = call_tool(job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_action_id])

    allow(StepDispatcher).to receive(:start_workflow)
    expect { pending_action.confirm!(user: user) }.not_to raise_error
    expect(pending_action.reload).to be_confirmed
    expect(pending_action.result).to be_a(Workflow)
    expect(pending_action.result.trigger_kind).to eq("coding_handoff")
  end
end

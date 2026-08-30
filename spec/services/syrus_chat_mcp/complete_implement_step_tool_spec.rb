require "rails_helper"

RSpec.describe Mcp::Tools::CompleteImplementStepTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "coding") }

  before do
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
    allow(WorkUnits::Launcher).to receive(:start!).and_call_original
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
      params: { name: "complete_implement_step", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "creates a pending handoff confirmation and leaves the coding Job locked" do
    job = Factories.job_record(repository: repository, state: "implemented", kind: "direct",
                               issue_number: nil, branch_name: "syrus/job-1", pr_number: 10)
    job.update_columns(linked_chat_id: chat_session.id, state: "coding")
    Workflow.create!(job: job, trigger_kind: "coding_handoff", state: "failed")

    response = call_tool(job_id: job.id)
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(result[:message]).to include("requires operator confirmation")
    pending_action = ChatPendingAction.find(result[:pending_action_id])
    expect(pending_action.action).to eq("complete_implement_step")
    expect(pending_action.payload).to eq("job_id" => job.id)
    expect(job.reload).to be_coding
    expect(job.linked_chat_id).to eq(chat_session.id)
    expect(WorkUnits::Launcher).not_to have_received(:start!)
  end

  it "creates a Local Mode pending handoff confirmation with the supplied branch" do
    chat_session.update!(mode: "local")
    Feature.find_or_create_by!(slug: "local_mode") do |record|
      record.category = "Labs"
      record.name = "Local Mode"
    end.update!(enabled: true)
    job = Factories.job_record(repository: repository, state: "implemented", kind: "direct",
                               issue_number: nil, branch_name: nil, pr_number: nil)
    job.update_columns(linked_chat_id: chat_session.id, state: "coding")

    response = call_tool(job_id: job.id, branch_name: "syrus/job-3931-local-run-command-input")
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    pending_action = ChatPendingAction.find(result[:pending_action_id])
    expect(pending_action.action).to eq("complete_implement_step")
    expect(pending_action.payload).to eq(
      "job_id" => job.id,
      "branch_name" => "syrus/job-3931-local-run-command-input"
    )
    expect(job.reload).to be_coding
    expect(job.branch_name).to be_nil
    expect(WorkUnits::Launcher).not_to have_received(:start!)
  end

  it "stores a supplied replacement branch_name on the pending action instead of mutating the Job immediately" do
    job = Factories.job_record(repository: repository, state: "implemented", kind: "direct",
                               issue_number: nil, branch_name: "syrus/stale", pr_number: nil)
    job.update_columns(linked_chat_id: chat_session.id, state: "coding")

    response = call_tool(job_id: job.id, branch_name: "syrus/fixed-rerun")
    result = payload(response)

    expect(response.dig(:result, :isError)).to be_falsey
    pending_action = ChatPendingAction.find(result[:pending_action_id])
    expect(pending_action.payload["branch_name"]).to eq("syrus/fixed-rerun")
    expect(job.reload.branch_name).to eq("syrus/stale")
  end

  it "rejects invalid replacement branch names" do
    job = Factories.job_record(repository: repository, state: "implemented", kind: "direct",
                               issue_number: nil, branch_name: "syrus/stale", pr_number: 10)
    job.update_columns(linked_chat_id: chat_session.id, state: "coding")

    response = call_tool(job_id: job.id, branch_name: "bad branch")

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not a valid branch name")
    expect(job.reload.branch_name).to eq("syrus/stale")
  end

  it "rejects an unknown job_id" do
    response = call_tool(job_id: 999_999_999)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not found")
  end

  it "rejects a job not in coding state" do
    job = Factories.job_record(repository: repository, state: "implemented")

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not in coding state")
  end

  it "rejects a job linked to a different chat session" do
    other_chat = ChatSession.create!(user: user, mode: "coding")
    job = Factories.job_record(repository: repository, state: "implemented", pr_number: 5)
    job.update_columns(linked_chat_id: other_chat.id, state: "coding")

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("not linked to this chat session")
  end

  it "requires branch_name for new jobs without a PR" do
    job = Factories.job_record(repository: repository, state: "running", kind: "direct", issue_number: nil)
    job.update_columns(linked_chat_id: chat_session.id, state: "coding", pr_number: nil, branch_name: nil)

    response = call_tool(job_id: job.id)

    expect(response.dig(:result, :isError)).to be(true)
    expect(response.dig(:result, :content, 0, :text)).to include("branch_name is required")
  end
end

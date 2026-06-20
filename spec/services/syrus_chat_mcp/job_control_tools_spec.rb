require "rails_helper"

RSpec.describe "SyrusChatMcp job control tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ApproveJobTool,
        SyrusChatMcp::UnapproveJobTool,
        SyrusChatMcp::SetJobPriorityTool,
        SyrusChatMcp::AssignJobToEpicTool,
        SyrusChatMcp::RemoveJobFromEpicTool,
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

  it "approves an implemented job" do
    job = Factories.job_record(repository: repository, state: "implemented")

    response = call_tool("approve_job", job_id: job.id)

    expect(payload(response)).to include(job_id: job.id, previous_state: "implemented", new_state: "approved")
    expect(job.reload).to be_approved
    expect(job.approved_via).to eq("operator")
    expect(job.approved_by_user).to eq(user)
  end

  it "rejects approving a job that is not implemented" do
    job = Factories.job_record(repository: repository, state: "queued")

    response = call_tool("approve_job", job_id: job.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("job must be in implemented state")
    expect(job.reload).to be_queued
  end

  it "unapproves an approved job" do
    job = Factories.job_record(repository: repository, state: "implemented")
    job.approve!(via: "operator", by_user: user)

    response = call_tool("unapprove_job", job_id: job.id)

    expect(payload(response)).to include(job_id: job.id, previous_state: "approved", new_state: "implemented")
    expect(job.reload).to be_implemented
    expect(job.approved_at).to be_nil
  end

  it "rejects unapproving a job that is not approved" do
    job = Factories.job_record(repository: repository, state: "implemented")

    response = call_tool("unapprove_job", job_id: job.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("job must be in approved state")
    expect(job.reload).to be_implemented
  end

  it "sets a job priority" do
    job = Factories.job_record(repository: repository, state: "queued", priority: "medium")

    response = call_tool("set_job_priority", job_id: job.id, priority: "high")

    expect(payload(response)).to include(job_id: job.id, previous_priority: "medium", new_priority: "high")
    expect(job.reload.priority).to eq("high")
  end

  it "rejects invalid job priorities" do
    job = Factories.job_record(repository: repository, state: "queued", priority: "medium")

    response = call_tool("set_job_priority", job_id: job.id, priority: "urgent")

    expect(response.dig(:error, :message)).to include("Invalid params")
    expect(job.reload.priority).to eq("medium")
  end

  it "assigns a job to an active epic" do
    job = Factories.job_record(repository: repository, state: "queued")
    epic = Factories.epic(user: user, repository: repository, title: "Migration train")

    response = call_tool("assign_job_to_epic", job_id: job.id, epic_id: epic.id)

    expect(payload(response)).to include(job_id: job.id, epic_id: epic.id, epic_title: "Migration train")
    expect(job.reload.epic).to eq(epic)
  end

  it "rejects assigning a job to an archived epic" do
    job = Factories.job_record(repository: repository, state: "queued")
    epic = Factories.epic(user: user, repository: repository, state: "archived")

    response = call_tool("assign_job_to_epic", job_id: job.id, epic_id: epic.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("epic must not be archived")
    expect(job.reload.epic_id).to be_nil
  end

  it "removes a job from its epic" do
    epic = Factories.epic(user: user, repository: repository, title: "Old epic")
    job = Factories.job_record(repository: repository, state: "queued", epic: epic)

    response = call_tool("remove_job_from_epic", job_id: job.id)

    expect(payload(response)).to include(job_id: job.id, removed_from_epic_id: epic.id, removed_from_epic_title: "Old epic")
    expect(job.reload.epic_id).to be_nil
  end

  it "rejects removing a job that is not assigned to an epic" do
    job = Factories.job_record(repository: repository, state: "queued")

    response = call_tool("remove_job_from_epic", job_id: job.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("job must currently belong to an epic")
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

  it "rejects epics outside the chat repository" do
    job = Factories.job_record(repository: repository, state: "queued")
    other_epic = Factories.epic(user: user, repository: Factories.repository(user: user))

    response = call_tool("assign_job_to_epic", job_id: job.id, epic_id: other_epic.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("epic not found in this repository")
    expect(job.reload.epic_id).to be_nil
  end
end

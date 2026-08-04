require "rails_helper"

RSpec.describe "SyrusChatMcp job control tools" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

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
        SyrusChatMcp::UpdateJobTool,
        SyrusChatMcp::CancelJobTool,
        SyrusChatMcp::CloseJobSuccessfullyTool,
        SyrusChatMcp::RetryJobTool,
        SyrusChatMcp::ForceFailJobTool,
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

  it "creates a pending close_job_successfully confirmation without executing it" do
    job = Factories.job_record(repository: repository, state: "approved", pr_number: 17)

    response = call_tool(
      "close_job_successfully",
      job_id: job.id,
      closure_reason: "no_changes",
      comment: "No unique patches remain against the stack parent."
    )
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action).to have_attributes(action: "close_job_successfully", requested_by: "agent")
    expect(pending_action.payload).to eq(
      "job_id" => job.id,
      "closure_reason" => "no_changes",
      "comment" => "No unique patches remain against the stack parent."
    )
    expect(job.reload).to be_approved
  end

  it "rejects close_job_successfully with a non-success closure reason" do
    job = Factories.job_record(repository: repository, state: "approved")

    response = call_tool("close_job_successfully", job_id: job.id, closure_reason: "cancelled")

    expect(response.dig(:result, :isError) || response.key?(:error)).to be_truthy
    expect(chat_session.pending_actions).to be_empty
  end

  it "anchors a pending action to the current assistant message" do
    job = Factories.job(repository: repository)
    message = chat_session.messages.create!(role: "assistant", content: { "text" => "I can cancel that." })

    allow(AppEvents).to receive(:broadcast)
    expect(AppEvents).to receive(:broadcast) do |user:, payload:, **|
      expect(user).to eq(chat_session.user)
      expect(payload).to include(
        action: "pending_action_updated",
        chat_message_id: message.id
      )
    end

    SyrusChatMcp::CancelJobTool.call(
      job_id: job.id,
      server_context: { chat_session: chat_session, current_message: message }
    )

    expect(message.reload.pending_action).to eq(chat_session.pending_actions.last)
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

  it "sets a job priority to urgent" do
    job = Factories.job_record(repository: repository, state: "queued", priority: "medium")

    response = call_tool("set_job_priority", job_id: job.id, priority: "urgent")

    expect(payload(response)).to include(job_id: job.id, previous_priority: "medium", new_priority: "urgent")
    expect(job.reload.priority).to eq("urgent")
  end

  it "rejects invalid job priorities" do
    job = Factories.job_record(repository: repository, state: "queued", priority: "medium")

    response = call_tool("set_job_priority", job_id: job.id, priority: "critical")

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

  it "updates a job title only" do
    job = Factories.job_record(repository: repository, issue_title: "Old title", issue_body: "Old description")

    response = call_tool("update_job", job_id: job.id, title: "New title")

    expect(payload(response)).to include(job_id: job.id, title: "New title", description: "Old description", state: "queued")
    expect(job.reload).to have_attributes(issue_title: "New title", issue_body: "Old description")
  end

  it "updates a job description only" do
    job = Factories.job_record(repository: repository, issue_title: "Old title", issue_body: "Old description")

    response = call_tool("update_job", job_id: job.id, description: "New description")

    expect(payload(response)).to include(job_id: job.id, title: "Old title", description: "New description", state: "queued")
    expect(job.reload).to have_attributes(issue_title: "Old title", issue_body: "New description")
  end

  it "updates a job title and description" do
    job = Factories.job_record(repository: repository, issue_title: "Old title", issue_body: "Old description")

    response = call_tool("update_job", job_id: job.id, title: "New title", description: "New description")

    expect(payload(response)).to include(job_id: job.id, title: "New title", description: "New description", state: "queued")
    expect(job.reload).to have_attributes(issue_title: "New title", issue_body: "New description")
  end

  it "rejects updating a job without a title or description" do
    job = Factories.job_record(repository: repository, issue_title: "Old title", issue_body: "Old description")

    response = call_tool("update_job", job_id: job.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("title or description is required")
    expect(job.reload).to have_attributes(issue_title: "Old title", issue_body: "Old description")
  end

  it "rejects updating a closed job" do
    job = Factories.job_record(
      repository: repository,
      state: "closed",
      issue_title: "Old title",
      issue_body: "Old description"
    )

    response = call_tool("update_job", job_id: job.id, title: "New title", description: "New description")

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("#{job.slug} is closed and cannot be updated.")
    expect(job.reload).to have_attributes(issue_title: "Old title", issue_body: "Old description")
  end

  it "updates jobs outside the pinned repository when they belong to the user" do
    other_job = Factories.job_record(repository: Factories.repository(user: user), issue_title: "Old title")

    response = call_tool("update_job", job_id: other_job.id, title: "New title")

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(job_id: other_job.id, title: "New title")
    expect(other_job.reload.issue_title).to eq("New title")
  end

  it "updates jobs without a repository pinned to the chat session" do
    chat_session.update!(repository: nil)
    job = Factories.job_record(repository: repository, issue_title: "Old title")

    response = call_tool("update_job", job_id: job.id, title: "New title")

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(job_id: job.id, title: "New title")
    expect(job.reload.issue_title).to eq("New title")
  end

  it "rejects updating jobs owned by another user" do
    other_job = Factories.job(repository: Factories.repository)

    response = call_tool("update_job", job_id: other_job.id, title: "New title")

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("job not found")
  end

  it "creates a pending retry_job confirmation without executing it" do
    job = Factories.job(repository: repository)

    response = call_tool("retry_job", job_id: job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action.action).to eq("retry_job")
    expect(job.workflows.where(trigger_kind: "retry")).to be_empty
  end

  it "requires admin access for force_fail_job" do
    job = Factories.job_record(repository: repository, state: "running")

    response = call_tool("force_fail_job", job_id: job.id, reason: "Testing non-admin denial.")

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("Admin access required")
    expect(chat_session.pending_actions.where(action: "force_fail_job")).to be_empty
    expect(job.reload).to be_running
  end

  it "does not let a non-admin confirm a crafted force_fail_job pending action" do
    job = Factories.job_record(repository: repository, state: "running")
    pending_action = chat_session.pending_actions.create!(
      action: "force_fail_job",
      payload: { "job_id" => job.id },
      reason: "Testing crafted action denial.",
      requested_by: "agent"
    )

    expect { pending_action.confirm!(user: user) }.to raise_error(ArgumentError, "Admin access required.")
    expect(job.reload).to be_running
  end

  it "creates a pending rebase_job confirmation without executing it" do
    job = Factories.job(repository: repository, pr_number: 12)

    response = call_tool("rebase_job", job_id: job.id, reason: "Bring the branch current.")
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(pending_action).to be_pending
    expect(pending_action.action).to eq("rebase_job")
    expect(job.workflows.where(trigger_kind: "rebase")).to be_empty
  end

  it "allows canceling jobs outside the chat repository when they belong to the chat user" do
    other_job = Factories.job(repository: Factories.repository(user: user))

    response = call_tool("cancel_job", job_id: other_job.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])

    expect(response.dig(:result, :isError)).to be_falsey
    expect(pending_action).to have_attributes(action: "cancel_job", payload: { "job_id" => other_job.id })
  end

  it "finds epics outside the pinned repository when they belong to the user" do
    other_repository = Factories.repository(user: user)
    job = Factories.job_record(repository: other_repository, state: "queued")
    other_epic = Factories.epic(user: user, repository: other_repository)

    response = call_tool("assign_job_to_epic", job_id: job.id, epic_id: other_epic.id)

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(job_id: job.id, epic_id: other_epic.id)
    expect(job.reload.epic_id).to eq(other_epic.id)
  end

  it "rejects epics owned by another user" do
    job = Factories.job_record(repository: repository, state: "queued")
    other_epic = Factories.epic

    response = call_tool("assign_job_to_epic", job_id: job.id, epic_id: other_epic.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("epic not found")
    expect(job.reload.epic_id).to be_nil
  end

  context "admin bypass" do
    let(:admin) { Factories.user(admin: true) }
    let(:other_user) { Factories.user }
    let(:other_repository) { Factories.repository(user: other_user) }
    let(:admin_chat_session) { ChatSession.create!(user: admin) }

    def admin_server
      MCP::Server.new(
        name: "syrus-chat-sidecar",
        tools: [
          SyrusChatMcp::ApproveJobTool,
          SyrusChatMcp::UnapproveJobTool,
          SyrusChatMcp::SetJobPriorityTool,
          SyrusChatMcp::CancelJobTool,
          SyrusChatMcp::CloseJobSuccessfullyTool,
          SyrusChatMcp::RetryJobTool,
          SyrusChatMcp::ForceFailJobTool,
          SyrusChatMcp::RebaseJobTool
        ],
        server_context: { chat_session: admin_chat_session }
      )
    end

    def admin_call(name, arguments = {})
      raw = admin_server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
      JSON.parse(raw, symbolize_names: true)
    end

    it "allows an admin to approve another user's job" do
      job = Factories.job_record(repository: other_repository, state: "implemented")

      response = admin_call("approve_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(job.reload).to be_approved
    end

    it "allows an admin to unapprove another user's job" do
      job = Factories.job_record(repository: other_repository, state: "implemented")
      job.approve!(via: "operator", by_user: other_user)

      response = admin_call("unapprove_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(job.reload).to be_implemented
    end

    it "allows an admin to set priority on another user's job" do
      job = Factories.job_record(repository: other_repository, state: "queued", priority: "medium")

      response = admin_call("set_job_priority", job_id: job.id, priority: "high")

      expect(response.dig(:result, :isError)).to be_falsey
      expect(job.reload.priority).to eq("high")
    end

    it "allows an admin to cancel another user's job" do
      job = Factories.job_record(repository: other_repository, state: "queued")

      response = admin_call("cancel_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
      pending_action = admin_chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])
      expect(pending_action).to have_attributes(action: "cancel_job", payload: { "job_id" => job.id })
    end

    it "allows an admin to request a successful close for another user's job" do
      job = Factories.job_record(repository: other_repository, state: "approved")

      response = admin_call("close_job_successfully", job_id: job.id, closure_reason: "no_changes")

      expect(response.dig(:result, :isError)).to be_falsey
      pending_action = admin_chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])
      expect(pending_action).to have_attributes(
        action: "close_job_successfully",
        payload: { "job_id" => job.id, "closure_reason" => "no_changes" }
      )
    end

    it "allows an admin to retry another user's job" do
      job = Factories.job_record(repository: other_repository, state: "queued")

      response = admin_call("retry_job", job_id: job.id)

      expect(response.dig(:result, :isError)).to be_falsey
      pending_action = admin_chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])
      expect(pending_action).to have_attributes(action: "retry_job", payload: { "job_id" => job.id })
    end

    it "creates and confirms a force_fail_job action for another user's job" do
      job = Factories.job_record(repository: other_repository, state: "running")

      response = admin_call("force_fail_job", job_id: job.id, reason: "Operator determined it is stuck.")

      expect(response.dig(:result, :isError)).to be_falsey
      response_payload = payload(response)
      expect(response_payload).to include(job_id: job.id, previous_state: "running", new_state: "failed")
      pending_action = admin_chat_session.pending_actions.find(response_payload[:pending_confirmation_id])
      expect(pending_action).to have_attributes(
        action: "force_fail_job",
        payload: { "job_id" => job.id, "previous_state" => "running" },
        reason: "Operator determined it is stuck."
      )
      expect(job.reload).to be_running

      expect(pending_action.confirm!(user: admin)).to be(true)
      expect(job.reload).to be_failed
      expect(pending_action.reload.result).to eq(job)
      expect(pending_action.before_snapshot.dig("jobs", 0, "state")).to eq("running")
      expect(pending_action.after_snapshot.dig("jobs", 0, "state")).to eq("failed")
    end

    it "allows an admin to rebase another user's job" do
      job = Factories.job_record(repository: other_repository, state: "queued", pr_number: 5)

      response = admin_call("rebase_job", job_id: job.id, reason: "Refresh mergeability.")

      expect(response.dig(:result, :isError)).to be_falsey
      pending_action = admin_chat_session.pending_actions.find(payload(response)[:pending_confirmation_id])
      expect(pending_action).to have_attributes(action: "rebase_job", payload: { "job_id" => job.id }, reason: "Refresh mergeability.")
    end
  end
end

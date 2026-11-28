require "rails_helper"

RSpec.describe "coworker Job lifecycle tools" do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-lifecycle", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:server_context) { { chat_session: chat, agent_actor: coworker } }

  before { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }

  def payload(response) = JSON.parse(response.content.first.fetch(:text))

  def allow_job_lifecycle!
    coworker.permission_rules.update!(
      capability: Permissions::JobLifecycle::JOBS.delete_suffix("@v1"),
      approval_policy: "auto",
      actor: owner
    )
  end

  it "inherits eligible shared Job lifecycle tools for coworkers" do
    coworker_tools = McpToolRegistry.entries(surface: :coworker).select do |entry|
      entry.descriptor.capability == Permissions::JobLifecycle::JOBS
    end.map(&:tool_name)
    eligible_chat_tools = McpToolRegistry.entries(surface: :chat).select do |entry|
      entry.descriptor.capability == Permissions::JobLifecycle::JOBS &&
        Mcp::ChatToolParity.core_entry_in_context?(entry, :coworker)
    end.map(&:tool_name)

    expect(coworker_tools).to match_array(eligible_chat_tools)
    expect(coworker_tools).to include("close_job_successfully", "approve_job", "retry_job")
  end

  it "uses the shared lifecycle descriptor and keeps replacement closes pending" do
    allow_job_lifecycle!
    duplicate = Factories.job_record(user: owner, repository:, state: "implemented")
    canonical = Factories.job_record(user: owner, repository:, state: "implemented", issue_number: 43)

    response = Mcp::Tools::CloseJobSuccessfullyTool.call(
      job_id: duplicate.id, closure_reason: "duplicate",
      references: [ { type: "Job", id: canonical.id } ],
      note: "QA confirmed the newer Job covers this work.",
      server_context:
    )

    result = payload(response)
    action = chat.pending_actions.find(result.fetch("pending_action_id"))
    entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool == Mcp::Tools::CloseJobSuccessfullyTool }
    expect(entry.descriptor).to have_attributes(
      capability: Permissions::JobLifecycle::JOBS,
      operation: "syrus.jobs/close@v1",
      defaults: include(AgentRole::COWORKER_CHAT => :ask)
    )
    expect(action).to have_attributes(
      action: "close_job_successfully", subject: coworker
    )
    expect(action.payload).to include(
      "job_id" => duplicate.id,
      "closure_reason" => "duplicate",
      "references" => [ { "type" => "Job", "id" => canonical.id } ]
    )
    expect(duplicate.reload).to be_implemented

    action.confirm!(user: owner)

    expect(duplicate.reload).to have_attributes(state: "closed", closure_reason: "duplicate")
    transition = StateTransition.for_subject(duplicate).recent.first
    expect(transition).to have_attributes(from_state: "implemented", to_state: "closed", source: "tool")
    expect(transition.metadata).to include(
      "actor_type" => "Coworkers::Coworker", "actor_id" => coworker.id, "chat_session_id" => chat.id,
      "references" => [ { "type" => "Job", "id" => canonical.id } ]
    )
  end

  it "closes its own Job without operator confirmation under autonomous lifecycle permission" do
    allow_job_lifecycle!
    job = Factories.job_record(
      user: owner, repository:, proposer: coworker, state: "implemented", kind: "coworker_task", issue_number: nil
    )

    response = Mcp::Tools::CloseJobSuccessfullyTool.call(
      job_id: job.id, closure_reason: "not_needed", server_context:
    )

    result = payload(response)
    action = chat.pending_actions.find(result.fetch("pending_action_id"))
    expect(result).to include("state" => "confirmed", "job_id" => job.id, "closure_reason" => "not_needed")
    expect(action).to have_attributes(state: "confirmed", subject: coworker)
    expect(job.reload).to have_attributes(state: "closed", closure_reason: "not_needed")
    transition = StateTransition.for_subject(job).recent.first
    expect(transition).to have_attributes(source: "tool", user: owner)
    expect(transition.metadata).to include(
      "actor_type" => "Coworkers::Coworker", "actor_id" => coworker.id, "chat_session_id" => chat.id
    )
  end

  it "keeps declined reasons pending despite autonomous lifecycle permission" do
    allow_job_lifecycle!
    job = Factories.job_record(
      user: owner, repository:, proposer: coworker, state: "implemented", kind: "coworker_task", issue_number: nil
    )

    response = Mcp::Tools::CloseJobSuccessfullyTool.call(
      job_id: job.id, closure_reason: "obsolete", server_context:
    )

    result = payload(response)
    expect(result).to include("state" => "pending")
    expect(chat.pending_actions.find(result.fetch("pending_action_id"))).to be_pending
    expect(job.reload).to be_implemented
  end

  it "rejects inaccessible Jobs without creating a pending action" do
    allow_job_lifecycle!
    inaccessible = Factories.job_record(repository: Factories.repository(user: Factories.user), state: "implemented")

    response = Mcp::Tools::CancelJobTool.call(job_id: inaccessible.id, reason: "Obsolete.", server_context:)

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(inaccessible.reload).to be_implemented
  end

  it "enforces a canonical deny rule before creating the lifecycle pending action" do
    job = Factories.job_record(user: owner, repository:, state: "implemented")
    descriptor = McpToolRegistry.entries(surface: :coworker)
      .find { |entry| entry.tool == Mcp::Tools::CloseJobSuccessfullyTool }.descriptor
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s, subject_role_keys: [],
      capability: descriptor.capability, operation: descriptor.operation,
      resource_type: descriptor.resource_scope.type.to_s, resource_scope: {}, constraints: {},
      policy: "deny", policy_layer: "agent", source: "operator", provenance: {}
    )

    response = Mcp::Tools::CloseJobSuccessfullyTool.call(
      job_id: job.id, closure_reason: "obsolete", server_context:
    )

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(job.reload).to be_implemented
  end
end

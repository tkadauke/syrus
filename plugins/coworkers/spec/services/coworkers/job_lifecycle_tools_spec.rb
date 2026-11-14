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

  it "registers every context-independent chat Job lifecycle tool for coworkers" do
    chat_tools = McpToolRegistry.entries(surface: :chat).select do |entry|
      entry.descriptor.capability == Permissions::JobLifecycle::JOBS && entry.tool != Mcp::Tools::CreateCodingJobTool
    end.map(&:tool_name)
    coworker_tools = McpToolRegistry.entries(surface: :coworker).select do |entry|
      entry.descriptor.capability == Permissions::JobLifecycle::JOBS
    end.map(&:tool_name)

    expect(coworker_tools).to match_array(chat_tools)
  end

  it "uses the shared lifecycle descriptor and mandatory cancellation pending action" do
    duplicate = Factories.job_record(user: owner, repository:, state: "implemented")
    canonical = Factories.job_record(user: owner, repository:, state: "implemented", issue_number: 43)

    response = Mcp::Tools::CancelJobTool.call(
      job_id: duplicate.id,
      reason: "QA confirmed the newer Job covers this work.",
      canonical_job_id: canonical.id,
      server_context:
    )

    result = payload(response)
    action = chat.pending_actions.find(result.fetch("pending_confirmation_id"))
    entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool == Mcp::Tools::CancelJobTool }
    expect(entry.descriptor).to have_attributes(
      capability: Permissions::JobLifecycle::JOBS,
      operation: "syrus.jobs/cancel@v1",
      defaults: include(AgentRole::COWORKER_CHAT => :ask)
    )
    expect(action).to have_attributes(
      action: "cancel_job", subject: coworker, reason: "QA confirmed the newer Job covers this work."
    )
    expect(action.payload).to include("job_id" => duplicate.id, "canonical_job_id" => canonical.id)
    expect(duplicate.reload).to be_implemented

    action.confirm!(user: owner)

    expect(duplicate.reload).to have_attributes(state: "closed", closure_reason: "duplicate", canonical_job_id: canonical.id)
    transition = StateTransition.for_subject(duplicate).recent.first
    expect(transition).to have_attributes(from_state: "implemented", to_state: "closed", source: "operator")
    expect(transition.metadata).to include(
      "actor_type" => "Coworkers::Coworker", "actor_id" => coworker.id, "chat_session_id" => chat.id,
      "human_reason" => "QA confirmed the newer Job covers this work.", "canonical_job_id" => canonical.id
    )
  end

  it "rejects inaccessible Jobs without creating a pending action" do
    inaccessible = Factories.job_record(repository: Factories.repository(user: Factories.user), state: "implemented")

    response = Mcp::Tools::CancelJobTool.call(job_id: inaccessible.id, reason: "Obsolete.", server_context:)

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(inaccessible.reload).to be_implemented
  end

  it "enforces a canonical deny rule before creating the lifecycle pending action" do
    job = Factories.job_record(user: owner, repository:, state: "implemented")
    descriptor = McpToolRegistry.entries(surface: :coworker)
      .find { |entry| entry.tool == Mcp::Tools::CancelJobTool }.descriptor
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s, subject_role_keys: [],
      capability: descriptor.capability, operation: descriptor.operation,
      resource_type: descriptor.resource_scope.type.to_s, resource_scope: {}, constraints: {},
      policy: "deny", policy_layer: "agent", source: "operator", provenance: {}
    )

    response = Mcp::Tools::CancelJobTool.call(job_id: job.id, reason: "Obsolete.", server_context:)

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(job.reload).to be_implemented
  end
end

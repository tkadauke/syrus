require "rails_helper"

RSpec.describe Mcp::Tools::ManageJobStateTool do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-job-state", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:server_context) { { chat_session: chat, agent_actor: coworker } }

  before { Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main") }

  def job(state: "implemented", repository: self.repository, **attributes)
    Factories.job_record(user: repository.user, repository:, state:, **attributes)
  end

  def payload(response) = JSON.parse(response.content.first.fetch(:text))

  def allow_tool
    descriptor = McpToolRegistry.entries(surface: :coworker).find { |entry| entry.tool == described_class }.descriptor
    PermissionRule.create!(
      owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s, subject_role_keys: [],
      capability: descriptor.capability, operation: descriptor.operation,
      resource_type: descriptor.resource_scope.type.to_s, resource_scope: {}, constraints: {},
      policy: "allow", policy_layer: "agent", source: "operator", provenance: {}
    )
  end

  it "defaults to confirmation and does not mutate before authorization" do
    duplicate = job

    response = described_class.call(job_id: duplicate.id, action: "close", reason: "Already covered elsewhere.", server_context:)

    expect(payload(response)).to include("pending_confirmation_id" => be_present)
    expect(duplicate.reload).to be_implemented
    expect(chat.pending_actions.where(action: "coworker_tool_call")).to exist
  end

  it "closes an implemented duplicate and returns its persisted audit record" do
    allow_tool
    duplicate = job
    canonical = job(issue_number: 43)

    response = described_class.call(
      job_id: duplicate.id, action: "close", reason: "QA confirmed the newer Job covers this work.",
      canonical_job_id: canonical.id, server_context:
    )

    result = payload(response)
    expect(result).to include("job_id" => duplicate.id, "state" => "closed", "closure_reason" => "duplicate", "canonical_job_id" => canonical.id)
    expect(duplicate.reload).to have_attributes(state: "closed", canonical_job_id: canonical.id)
    transition = StateTransition.find(result.dig("audit", "id"))
    expect(transition).to have_attributes(from_state: "implemented", to_state: "closed", source: "operator")
    expect(transition.metadata).to include(
      "actor_type" => "Coworkers::Coworker", "actor_id" => coworker.id, "chat_session_id" => chat.id,
      "human_reason" => "QA confirmed the newer Job covers this work.", "canonical_job_id" => canonical.id
    )

    read_back = payload(Mcp::Tools::ReadJobTool.call(job_id: duplicate.id, server_context:))
    expect(read_back.dig("job", "state_transitions", 0)).to include(
      "from_state" => "implemented", "to_state" => "closed",
      "metadata" => include("actor_id" => coworker.id, "chat_session_id" => chat.id,
        "human_reason" => "QA confirmed the newer Job covers this work.", "canonical_job_id" => canonical.id)
    )
  end

  it "rejects inaccessible Jobs without mutation" do
    allow_tool
    other_owner = Factories.user
    inaccessible = job(repository: Factories.repository(user: other_owner))

    response = described_class.call(job_id: inaccessible.id, action: "cancel", reason: "Out of date.", server_context:)

    expect(response).to be_error
    expect(inaccessible.reload).to be_implemented
  end

  it "rejects landed and stale transitions while returning the current state" do
    allow_tool
    landed = job(landed_sha: "abc123")
    stale = job(state: "closed", closure_reason: "cancelled")

    landed_result = payload(described_class.call(job_id: landed.id, action: "close", reason: "Looks obsolete.", server_context:))
    stale_result = payload(described_class.call(job_id: stale.id, action: "cancel", reason: "Looks obsolete.", server_context:))

    expect(landed_result).to include("ok" => false, "state" => "implemented")
    expect(stale_result).to include("ok" => false, "state" => "closed")
    expect(landed.reload).to be_implemented
  end

  it "registers only narrow state-management authority with an ask default" do
    entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool == described_class }

    expect(entry).to have_attributes(capability: :"syrus.manage_job_state", mutation: true)
    expect(entry.descriptor).to have_attributes(effects: [ :internal_write ], risk: :high)
    expect(Permissions::CoworkerDefaultPolicy.verdict(entry.descriptor).policy).to eq(:ask)
  end
end

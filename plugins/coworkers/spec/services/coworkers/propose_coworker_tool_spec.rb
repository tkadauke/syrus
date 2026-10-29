require "rails_helper"

RSpec.describe Coworkers::McpTools::ProposeCoworkerTool do
  class ProposalCoworkerRemote
    attr_reader :repository, :seeded_files, :push_tests
    attr_accessor :branch_exists, :fail_access

    def initialize(user)
      @repository = Repository.new(owner: "acme", name: "coworker-homes", user: user)
    end

    def branch_exists?(_branch) = branch_exists

    def test_push_access!
      @push_tests = push_tests.to_i + 1
      raise "push denied" if fail_access
    end

    def seed!(branch:, files:, identity:) = @seeded_files = files
    def delete!(_branch) = nil
  end

  let(:owner) { Factories.user }
  let(:chat) { ChatSession.create!(user: owner) }
  let(:remote) { ProposalCoworkerRemote.new(owner) }
  let(:fields) do
    { name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/coworker-homes.git",
      about: "Research lead\nCurious and concise.", color_key: "coral-deep", chat_provider: "codex",
      chat_model: "gpt-5.6-sol", chat_effort: "high", grants: [ "workspace.files", "syrus.read_jobs" ] }
  end

  before { allow(Coworkers::RemoteWorkspace).to receive(:new).and_return(remote) }
  before { allow_any_instance_of(User).to receive(:chat_provider_configured?).with("codex").and_return(true) }

  def propose(**overrides)
    described_class.call(**fields.merge(overrides), server_context: { chat_session: chat })
  end

  def response_payload(response)
    JSON.parse(response.content.first.fetch(:text))
  end

  it "preflights but creates nothing before confirmation, then creates exactly the shown fields" do
    response = propose
    expect(response).not_to be_error
    expect(chat.pending_actions.count).to eq(1)
    expect(Coworkers::Coworker.count).to eq(0)
    expect(ChatSession.where.not(id: chat.id).count).to eq(0)

    action = chat.pending_actions.last
    expect(action.payload).to eq(fields.deep_stringify_keys)
    expect(response_payload(response).fetch("coworker")).to include(
      action.payload.merge("branch" => "coworkers/maya", "grant_policies" => { "workspace.files" => "auto", "syrus.read_jobs" => "auto" })
    )
    expect(remote.push_tests).to eq(1)

    expect(action.confirm!).to be true
    coworker = Coworkers::Coworker.find_by!(handle: "maya")
    expect(coworker).to have_attributes(fields.slice(:name, :color_key, :chat_provider, :chat_model, :chat_effort))
    expect(coworker.workspace_repo).to eq("https://github.com/acme/coworker-homes.git")
    expect(coworker.grants.pluck(:capability)).to contain_exactly(*fields[:grants])
    expect(remote.seeded_files.fetch("SOUL.md")).to include(fields[:about])
    expect(PendingActions::CreateCoworker.new(action.reload).tool_card_outcome).to eq(
      coworker_id: coworker.id, chat_id: coworker.coworker_chats.find_by!(role: "main").chat_session_id
    )
  end

  it "creates nothing when withdrawn or rejected" do
    propose
    PendingActions::Withdrawal.new(chat.pending_actions.last, user: owner).call
    propose(handle: "maya-two")
    chat.pending_actions.last.reject!

    expect(Coworkers::Coworker.count).to eq(0)
  end

  it "loses a handle race safely at confirmation" do
    propose
    action = chat.pending_actions.last
    Handle.create!(handle: "maya")

    expect { action.confirm! }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Coworkers::Coworker.count).to eq(0)
    expect(remote.seeded_files).to be_nil
  end

  it "rejects a remote that fails the optional push test without a pending action" do
    remote.fail_access = true

    response = propose

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(Coworkers::Coworker.count).to eq(0)
  end

  it "rejects an unavailable model before creating a pending action" do
    response = propose(chat_model: "not-a-model")

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
    expect(remote.push_tests).to be_nil
  end

  it "is not advertised in coworker threads" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "other-maya", workspace_repo: "git@example.com:workspaces.git")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    expect(Coworkers::ChatToolSet.available_for?(chat, tier: :deferred)).to be false
  end
end

RSpec.describe Coworkers::McpTools::ProposeGrantEscalationTool do
  let(:owner) { Factories.user }
  let(:chat) { ChatSession.create!(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-grants", workspace_repo: "git@example.com:workspaces.git"
    )
  end

  def propose(grants)
    described_class.call(coworker_id: coworker.id, grants: grants, server_context: { chat_session: chat })
  end

  it "normalizes an escalation into its own pending action and grants exactly those capabilities on confirmation" do
    response = propose([ "syrus.read_jobs", "workspace.shell", "syrus.read_jobs" ])
    action = chat.pending_actions.last

    expect(response).not_to be_error
    expect(action).to have_attributes(
      action: "escalate_coworker_grants",
      payload: { "coworker_id" => coworker.id, "handle" => "maya-grants", "grants" => [ "syrus.read_jobs", "workspace.shell" ] }
    )
    expect(coworker.grants).to be_empty
    expect(JSON.parse(response.content.first.fetch(:text)).fetch("grant_escalation")).to eq(action.payload)

    expect(action.confirm!).to be true
    expect(coworker.grants.reload.pluck(:capability, :approval_policy).to_h).to eq(
      "syrus.read_jobs" => "auto", "workspace.shell" => "auto"
    )
  end

  it "adds nothing when the escalation is rejected" do
    propose([ "workspace.shell" ])
    chat.pending_actions.last.reject!

    expect(coworker.grants).to be_empty
  end

  it "rechecks escalation races at confirmation" do
    propose([ "workspace.shell" ])
    action = chat.pending_actions.last
    coworker.grants.create!(capability: "workspace.shell", approval_policy: "auto")

    expect { action.confirm! }.to raise_error(ArgumentError, /already granted/)
    expect(coworker.grants.where(capability: "workspace.shell").count).to eq(1)
  end

  it "cannot escalate a coworker owned by another user" do
    other = Factories.user
    other_coworker = Coworkers::Coworker.create!(
      owner_user: other, name: "Other", handle: "other-grants", workspace_repo: "git@example.com:other.git"
    )

    response = described_class.call(
      coworker_id: other_coworker.id, grants: [ "workspace.shell" ], server_context: { chat_session: chat }
    )

    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
  end
end

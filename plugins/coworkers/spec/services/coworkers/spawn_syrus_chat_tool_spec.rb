require "rails_helper"

RSpec.describe Coworkers::SpawnSyrusChatTool do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:other_repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-engineering",
      workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository:, title: "Maya") }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "Start engineering" }, skip_turn_trigger: true) }
  let(:context) { { chat_session: chat, current_message: message } }
  let(:scope) { Syrus::EffectScope.new(label: "spawn Syrus chat spec") }

  before do
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    coworker.grants.create!(capability: "syrus.spawn_chat", approval_policy: "confirm", scope: [ repository.id ])
    Coworkers::ChatExtension.install_into(scope)
  end
  after { scope.dispose }

  def payload(response) = JSON.parse(response.content.first.fetch(:text))

  it "creates one approval card and then an ordinary repository chat with provenance and a bridge" do
    response = described_class.call(repository_id: repository.id, prompt: "Plan the release", title: "Release", server_context: context)
    action = chat.pending_actions.find(payload(response).fetch("pending_action_id"))

    expect(chat.pending_actions.where(action: "coworker_tool_call")).to contain_exactly(action)
    expect(Coworkers::ChatToolSet.tool_definitions(tier: :essential).find { |tool| tool[:name] == "spawn_syrus_chat" })
      .to include(capability: "syrus.spawn_chat", ungated: true)

    operation = action.authorization_items.find_by!(kind: "operation")
    Permissions::CoworkerAuthorizationDecision.new(request: action, item: operation, user: owner).call(decision: "approved")
    expect { action.execute_confirmation!(raise_on_error: true) }.to change(ChatSession, :count).by(1)

    spawned = ChatSession.order(:id).last
    expect(spawned).to have_attributes(user: owner, title: "Release")
    expect(spawned.attached_repositories).to contain_exactly(repository)
    expect(spawned.artifacts.fetch("opened_by_coworker")).to include("handle" => coworker.handle)
    expect(Coworkers::Chat.exists?(chat_session: spawned)).to eq(false)
    thread = ChatBridgeThread.find_by!(origin_chat_session: chat, target_chat_session: spawned)
    expect(thread.opened_by_user).to eq(owner)
    expect(ChatWakeup.find_by!(chat_session: spawned).metadata).to include("thread_id" => thread.id)
    expect(Permissions::CoworkerAudit.events_for(coworker).last.action).to eq("coworker_syrus_chat_spawned")
  end

  it "refuses repositories outside the grant scope before creating an approval" do
    response = described_class.call(repository_id: other_repository.id, prompt: "Plan it", server_context: context)
    expect(response).to be_error
    expect(chat.pending_actions).to be_empty
  end

  it "uses independent per-run caps" do
    coworker.grants.find_by!(capability: "syrus.spawn_chat").update!(
      constraints: { "max_spawns_per_run" => 1, "max_spawns_per_day" => 2 }
    )
    expect(described_class.call(repository_id: repository.id, prompt: "One", server_context: context)).not_to be_error
    response = described_class.call(repository_id: repository.id, prompt: "Two", server_context: context)
    expect(response.content.first.fetch(:text)).to include("at most 1 per run")
  end
end

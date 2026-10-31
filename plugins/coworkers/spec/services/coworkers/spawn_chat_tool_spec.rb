require "rails_helper"

RSpec.describe Coworkers::SpawnChatTool do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-spawn",
      workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "Split this out" }, skip_turn_trigger: true) }
  let(:context) { { chat_session: chat, current_message: message } }
  let(:scope) { Syrus::EffectScope.new(label: "spawn chat spec") }

  before do
    PluginRecord.find_or_create_by!(name: "coworkers").update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    allow(ChatSessions::Creator).to receive(:enqueue_turn)
  end
  after { scope.dispose }

  def payload(response) = JSON.parse(response.content.first.fetch(:text))
  def error_text(response) = response.content.first.fetch(:text)

  it "is absent and refuses calls without the grant" do
    definitions = Coworkers::ChatToolSet.tool_definitions(tier: :essential)
    expect(definitions.find { |definition| definition[:name] == "spawn_coworker_chat" }).to include(
      capability: "coworker.spawn_chat", mutation: true
    )

    response = described_class.call(prompt: "Investigate", server_context: context)
    expect(response).to be_error
    expect(error_text(response)).to include("grant is required")
  end

  it "creates a confirm pending action and then a side chat of the same coworker" do
    coworker.grants.create!(capability: "coworker.spawn_chat", approval_policy: "confirm")

    response = described_class.call(prompt: "Investigate the flaky test", title: "Flake", server_context: context)
    action = chat.pending_actions.find(payload(response).fetch("pending_action_id"))

    expect(action.payload).to include("tool_name" => "spawn_coworker_chat", "approval_policy" => "confirm")
    expect { action.confirm!(user: owner) }.to change(Coworkers::Chat.where(coworker:, role: "side"), :count).by(1)
    spawned = coworker.coworker_chats.find_by!(role: "side").chat_session
    expect(spawned.messages.first.content.fetch("text")).to eq("Investigate the flaky test")
    expect(McpToolContext.from_chat_session(spawned).granted_capabilities).to include("coworker.spawn_chat")
    expect(ChatSessions::Creator).to have_received(:enqueue_turn).with(spawned, spawned.messages.first)
  end

  it "refuses another coworker handle" do
    coworker.grants.create!(capability: "coworker.spawn_chat", approval_policy: "confirm")
    response = described_class.call(prompt: "Nope", handle: "someone-else", server_context: context)
    expect(response).to be_error
    expect(error_text(response)).to include("only spawn a side chat of itself")
    expect(chat.pending_actions).to be_empty
  end

  it "queues the pending action from an unattended run" do
    coworker.grants.create!(capability: "coworker.spawn_chat", approval_policy: "confirm")
    run = instance_double(Run, id: 123)
    run_context = McpToolContext.new(surface: :run, role: AgentRole::COWORKER, user: owner, run:, chat_session: chat,
      granted_capabilities: [ "coworker.spawn_chat" ], capability_approval_policies: { "coworker.spawn_chat" => "queue" },
      agent_actor: coworker)
    allow(McpToolContext).to receive(:from_server_context).with({ run: run }).and_return(run_context)

    response = described_class.call(prompt: "Follow up", server_context: { run: run })
    action = chat.pending_actions.find(payload(response).fetch("pending_action_id"))
    expect(action.payload).to include("approval_policy" => "queue", "approval_inbox" => true, "run_id" => run.id)
  end

  it "enforces configurable per-run and per-day caps with pending requests reserving capacity" do
    coworker.grants.create!(capability: "coworker.spawn_chat", approval_policy: "confirm",
      constraints: { "max_spawns_per_run" => 1, "max_spawns_per_day" => 2 })

    expect(described_class.call(prompt: "One", server_context: context)).not_to be_error
    per_run = described_class.call(prompt: "Two", server_context: context)
    expect(error_text(per_run)).to include("at most 1 per run")

    second_message = chat.messages.create!(role: "user", content: { "text" => "Again" }, skip_turn_trigger: true)
    expect(described_class.call(prompt: "Two", server_context: { chat_session: chat, current_message: second_message })).not_to be_error
    third_message = chat.messages.create!(role: "user", content: { "text" => "Again" }, skip_turn_trigger: true)
    per_day = described_class.call(prompt: "Three", server_context: { chat_session: chat, current_message: third_message })
    expect(error_text(per_day)).to include("at most 2 per day")
  end
end

require "rails_helper"

RSpec.describe ChatIdentityContributions do
  let(:user) { instance_double(User) }
  let(:chat) { instance_double(ChatSession, id: 11) }
  let(:message) { instance_double(ChatMessage, id: 21) }

  before { Syrus::PluginRegistry.reset! }
  after { Syrus::PluginRegistry.reset! }

  it "normalizes structured identities and preserves their historical display snapshots" do
    provider = synthetic_provider do
      define_singleton_method(:chat_identities) do |chat_session:, user:|
        [ { provider: "test_agents", kind: :agent, id: 7, snapshot: { label: "Ada", handle: "ada" } } ]
      end
      define_singleton_method(:chat_turn_identity) do |chat_session:, message:|
        { provider: "test_agents", kind: "agent", id: "7", snapshot: { label: "Ada", handle: "ada" } }
      end
    end

    register(provider)

    identity = described_class.identities(chat_session: chat, user: user).sole
    expect(identity).to eq(
      "provider" => "test_agents", "kind" => "agent", "id" => "7",
      "snapshot" => { "label" => "Ada", "handle" => "ada" }
    )
    expect(described_class.turn_identity(chat_session: chat, message: message)).to include("snapshot" => include("label" => "Ada"))
    expect(identity).to be_frozen
    expect(identity.fetch("snapshot")).to be_frozen
  end

  it "uses the first provider that owns a turn trigger decision" do
    observer = synthetic_provider
    owner = synthetic_provider do
      define_singleton_method(:chat_turn_trigger) do |chat_session:, message:, mentions:|
        { trigger: false, reason: "addressed to another agent", metadata: { owner: "test_agents" } }
      end
    end
    register(observer)
    register(owner)

    expect(described_class.trigger_decision(chat_session: chat, message: message, mentions: [])).to eq(
      "trigger" => false,
      "reason" => "addressed to another agent",
      "metadata" => { "owner" => "test_agents" }
    )
  end

  it "lets a synthetic identity provider own a turn without changing the host fallback" do
    chat_session = ChatSession.new
    expect(chat_session.should_trigger_agent?([])).to be(true)

    provider = synthetic_provider do
      define_singleton_method(:chat_turn_trigger) do |chat_session:, message:, mentions:|
        { trigger: false, reason: "provider-owned quiet turn" }
      end
    end
    register(provider)

    expect(chat_session.should_trigger_agent?([])).to be(false)
  end

  it "collects explicit search and group ownership without allowing key collisions" do
    first = synthetic_provider do
      define_singleton_method(:chat_search_ownership) { |user:| { key: "test-agent", filter_field: "test_agent_id" } }
      define_singleton_method(:chat_group_ownership) { |user:| { key: "test-agents", label: "Test agents" } }
    end
    second = synthetic_provider do
      define_singleton_method(:chat_group_ownership) { |user:| { key: "test-agents", label: "Duplicate" } }
    end
    register(first)

    expect(described_class.search_ownership(user: user)).to eq([ { "key" => "test-agent", "filter_field" => "test_agent_id" } ])
    expect(described_class.group_ownership(user: user)).to eq([ { "key" => "test-agents", "label" => "Test agents" } ])

    register(second)
    expect { described_class.group_ownership(user: user) }
      .to raise_error(described_class::ContractError, /duplicate chat_group_ownership key/)
  end

  it "batches message presentation and chat status contributions" do
    other_message = instance_double(ChatMessage, id: 22)
    other_chat = instance_double(ChatSession, id: 12)
    provider = synthetic_provider do
      define_singleton_method(:chat_message_presentations) do |messages:|
        { messages.first.id => { variant: "agent_message", identity_snapshot: { label: "Ada" } } }
      end
      define_singleton_method(:chat_status_contributions) do |chat_sessions:, user:|
        { chat_sessions.last.id => { unread: true, status: "waiting" } }
      end
    end
    register(provider)

    expect(described_class.message_presentations(messages: [ message, other_message ])).to eq(
      21 => { "variant" => "agent_message", "identity_snapshot" => { "label" => "Ada" } }
    )
    expect(described_class.status_contributions(chat_sessions: [ chat, other_chat ], user: user)).to eq(
      12 => { "unread" => true, "status" => "waiting" }
    )
  end

  it "rejects malformed identities, decisions, and contributions for unknown records" do
    provider = synthetic_provider do
      define_singleton_method(:chat_identities) { |chat_session:, user:| [ { kind: "agent", id: 7, snapshot: { label: "Ada" } } ] }
      define_singleton_method(:chat_turn_trigger) { |chat_session:, message:, mentions:| { trigger: "yes", reason: "invalid" } }
      define_singleton_method(:chat_message_presentations) { |messages:| { 999 => { variant: "agent_message" } } }
    end
    register(provider)

    expect { described_class.identities(chat_session: chat, user: user) }
      .to raise_error(described_class::ContractError, /identity must contain non-blank provider/)
    expect { described_class.trigger_decision(chat_session: chat, message: message, mentions: []) }
      .to raise_error(described_class::ContractError, /boolean trigger/)
    expect { described_class.message_presentations(messages: [ message ]) }
      .to raise_error(described_class::ContractError, /unknown id/)
  end

  def synthetic_provider(&definition)
    Class.new do
      include Syrus::Plugin::ChatIdentityProvider
      class_eval(&definition) if definition
    end
  end

  def register(provider)
    Syrus::PluginRegistry.register_direct(:chat_identity_provider, provider)
  end
end

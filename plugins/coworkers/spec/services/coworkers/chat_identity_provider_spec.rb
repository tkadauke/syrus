require "rails_helper"

RSpec.describe Coworkers::ChatIdentityProvider do
  let(:owner) { Factories.user }
  let(:chat) { ChatSession.create!(user: owner, title: "Planning") }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya-identity",
      workspace_repo: "git@example.com:workspaces.git"
    )
  end

  it "owns linked identity, grouping, and historical status snapshots" do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")

    expect(described_class.chat_identities(chat_session: chat, user: owner).sole).to include(
      provider: "coworkers", kind: "coworker", id: coworker.id,
      snapshot: include(label: "Maya", handle: "maya-identity")
    )
    expect(described_class.chat_group_ownership(user: owner)).to include(
      key: "coworkers", chat_session_ids: [ chat.id ]
    )
    expect(described_class.chat_status_contributions(chat_sessions: [ chat ], user: owner))
      .to include(chat.id => include(identity: include(id: coworker.id)))
  end

  it "owns the coworker chat search filter" do
    expect(described_class.chat_search_ownership(user: owner)).to eq(
      key: "coworkers", filter_field: "coworker_id"
    )
  end

  it "suppresses a roster-mentioned source chat turn without claiming its identity" do
    Coworkers::ChatAgent.create!(chat_session: chat, coworker: coworker, added_by_user: owner)
    message = chat.messages.create!(
      role: "user", content: { "text" => "@maya-identity help" },
      mentions: [ { "kind" => "coworker", "id" => coworker.id, "handle" => coworker.handle, "start" => 0, "end" => 14 } ],
      skip_turn_trigger: true
    )

    expect(described_class.chat_turn_identity(chat_session: chat, message: message)).to be_nil
    expect(described_class.chat_turn_trigger(chat_session: chat, message: message, mentions: message.resolved_mentions))
      .to include(trigger: false, reason: "delegated coworker mention")
  end

  it "preserves direct and group-chat turn trigger decisions" do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    direct = described_class.chat_turn_trigger(chat_session: chat, message: nil, mentions: [])
    expect(direct).to include(trigger: true)

    other_human = Factories.user
    ChatParticipant.create!(chat_session: chat, user: other_human, role: "member", joined_at: Time.current)
    quiet = described_class.chat_turn_trigger(chat_session: chat, message: nil, mentions: [])
    addressed = described_class.chat_turn_trigger(
      chat_session: chat, message: nil,
      mentions: [ { "kind" => "coworker", "id" => coworker.id.to_s } ]
    )

    expect(quiet).to include(trigger: false)
    expect(addressed).to include(trigger: true)
  end

  it "decorates coworker messages through the identity presentation contract" do
    message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Message from @maya-identity", "source" => "coworker_message",
        "coworker_message" => { "direction" => "incoming", "sender_id" => coworker.id }
      },
      skip_turn_trigger: true
    )

    expect(described_class.chat_message_presentations(messages: [ message ]).dig(message.id, :plugin_message, :data, :appearance))
      .to include(handle: "maya-identity")
  end

  it "links delivered mention replies back to their working session" do
    message = chat.messages.create!(
      role: "assistant",
      content: {
        "text" => "Done", "source" => "coworker_message", "origin_chat_session_id" => 321,
        "coworker_message" => { "direction" => "incoming", "sender_id" => coworker.id, "sender_handle" => coworker.handle }
      },
      skip_turn_trigger: true
    )

    data = described_class.chat_message_presentations(messages: [ message ]).dig(message.id, :plugin_message, :data)

    expect(data).to include(appearance: include(name: "Maya"), working_session_id: 321)
  end

  it "decorates an inbound historical bridge without a legacy payload writer" do
    source_chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: source_chat, role: "main")
    message = chat.messages.create!(
      role: "user",
      content: {
        "text" => "Approved direction.", "requested_by" => "cross_chat",
        "origin_chat_session_id" => source_chat.id
      },
      skip_turn_trigger: true
    )

    presentation = described_class.chat_message_presentations(messages: [ message ]).dig(message.id, :plugin_message)

    expect(presentation).to include(component: "coworkers/CoworkerMessage")
    expect(presentation.dig(:data, :appearance)).to include(id: coworker.id, handle: "maya-identity")
  end

  it "keeps historical message metadata safe when its identity no longer exists" do
    message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Message from @retired", "source" => "coworker_message",
        "coworker_message" => { "direction" => "incoming", "sender_id" => 999_999, "sender_handle" => "retired" }
      },
      skip_turn_trigger: true
    )

    presentation = described_class.chat_message_presentations(messages: [ message ]).dig(message.id, :plugin_message)

    expect(presentation.dig(:data)).to include(appearance: nil, direction: "incoming", handle: "retired")
  end

  it "computes coworker message presentations once during generic serialization" do
    message = chat.messages.create!(
      role: "system",
      content: {
        "text" => "Message from @maya-identity", "source" => "coworker_message",
        "coworker_message" => { "direction" => "incoming", "sender_id" => coworker.id }
      },
      skip_turn_trigger: true
    )
    expect(Coworkers::PayloadContributor).to receive(:message_presentations)
      .once.and_call_original

    payload = App::ChatMessagePayload.messages([ message ], repository: nil).sole

    expect(payload.dig(:plugin_message, "data", "appearance")).to include("handle" => "maya-identity")
  end
end

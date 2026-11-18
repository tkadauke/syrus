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

  it "leaves roster mentions outside its source-chat turn ownership" do
    Coworkers::ChatAgent.create!(chat_session: chat, coworker: coworker, added_by_user: owner)
    message = chat.messages.create!(
      role: "user", content: { "text" => "@maya-identity help" },
      mentions: [ { "kind" => "coworker", "id" => coworker.id, "handle" => coworker.handle, "start" => 0, "end" => 14 } ],
      skip_turn_trigger: true
    )

    expect(described_class.chat_turn_identity(chat_session: chat, message: message)).to be_nil
    expect(described_class.chat_turn_trigger(chat_session: chat, message: message, mentions: message.resolved_mentions))
      .to be_nil
    expect(chat.should_trigger_agent?(message.resolved_mentions)).to be(false)
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

  it "decorates two delivered mention replies with their own authors and working sessions" do
    other = Coworkers::Coworker.create!(
      owner_user: owner, name: "Rin", handle: "rin-identity",
      workspace_repo: "git@example.com:workspaces.git", accent_hex: "#663399"
    )
    maya_session = ChatSession.create!(user: owner, title: "Maya work")
    rin_session = ChatSession.create!(user: owner, title: "Rin work")
    Coworkers::Chat.create!(coworker:, chat_session: maya_session, source_chat_session: chat, role: "mention")
    Coworkers::Chat.create!(coworker: other, chat_session: rin_session, source_chat_session: chat, role: "mention")
    messages = [ [ coworker, maya_session ], [ other, rin_session ] ].map do |author, session|
      chat.messages.create!(
        role: "assistant", skip_turn_trigger: true,
        content: { "text" => "Reply from #{author.name}", "source" => "coworker_message",
          "origin_chat_session_id" => session.id,
          "coworker_message" => { "direction" => "incoming", "sender_id" => author.id, "sender_handle" => author.handle } }
      )
    end

    presentations = described_class.chat_message_presentations(messages: messages)

    expect(presentations.dig(messages.first.id, :plugin_message, :data)).to include(
      appearance: include(name: "Maya"), working_chat_id: maya_session.id
    )
    expect(presentations.dig(messages.second.id, :plugin_message, :data)).to include(
      appearance: include(name: "Rin"), working_chat_id: rin_session.id
    )
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

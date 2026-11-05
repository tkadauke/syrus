require "rails_helper"

RSpec.describe Coworkers::PayloadContributor do
  let(:owner) { Factories.user }
  let(:plain_chat) { ChatSession.create!(user: owner, title: "Planning") }
  let(:coworker_chat) { ChatSession.create!(user: owner, title: "Monica") }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Monica", handle: "monica", accent_hex: "#E5484D",
      avatar_key: "spark", workspace_repo: "git@example.com:workspaces.git"
    )
  end

  it "decorates an inbound bridge from a coworker chat with the coworker's appearance" do
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")
    message = plain_chat.messages.create!(role: "user", content: { "text" => "Approved direction." })
    payload = {
      cross_chat_bridge: {
        direction: "inbound", counterpart_chat_session_id: coworker_chat.id,
        counterpart_chat_title: coworker_chat.title
      }
    }

    result = described_class.chat_message_payload(messages: [ message ], payloads: [ payload ]).sole

    expect(result.fetch(:coworker_sender)).to include(
      id: coworker.id, name: "Monica", handle: "monica", accent_hex: "#E5484D", avatar_key: "spark"
    )
  end

  it "does not expose a coworker owned by someone else through bridge metadata" do
    other_owner = Factories.user(email_address: "other@example.com")
    other_chat = ChatSession.create!(user: other_owner, title: "Hidden")
    other_coworker = Coworkers::Coworker.create!(
      owner_user: other_owner, name: "Hidden", handle: "hidden", workspace_repo: "git@example.com:hidden.git"
    )
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_chat, role: "main")
    message = plain_chat.messages.create!(role: "user", content: { "text" => "Hello." })
    payload = { cross_chat_bridge: { direction: "inbound", counterpart_chat_session_id: other_chat.id } }

    result = described_class.chat_message_payload(messages: [ message ], payloads: [ payload ]).sole

    expect(result).not_to have_key(:coworker_sender)
  end
end

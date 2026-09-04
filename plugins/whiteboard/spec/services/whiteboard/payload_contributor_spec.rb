require "rails_helper"

RSpec.describe Whiteboard::PayloadContributor do
  let(:repo) { Factories.repository }
  let(:chat) { ChatSession.create!(repository: repo, user: repo.user) }

  def board(elements)
    Whiteboard::Board.create!(chat_session: chat, scene_json: { "elements" => elements, "appState" => {}, "files" => {} })
  end

  it "omits the scene unless the request asked for it" do
    board([ { "id" => "a" } ])

    payload = described_class.chat_payload(chat_session: chat, context: { params: {} })

    expect(payload[:whiteboard][:loaded]).to be(false)
    expect(payload[:whiteboard][:elements]).to eq([])
  end

  it "serializes the scene when include_whiteboard is present" do
    board([ { "id" => "a" } ])

    payload = described_class.chat_payload(chat_session: chat, context: { params: { include_whiteboard: "1" } })

    expect(payload[:whiteboard][:loaded]).to be(true)
    expect(payload[:whiteboard][:elements]).to eq([ { "id" => "a" } ])
  end

  it "reports an empty loaded scene when the chat has no whiteboard yet" do
    payload = described_class.chat_payload(chat_session: chat, context: { params: { include_whiteboard: "1" } })

    expect(payload[:whiteboard][:loaded]).to be(true)
    expect(payload[:whiteboard][:elements]).to eq([])
  end

  it "contributes its path and snapshot count" do
    Whiteboard::Snapshot.create!(
      chat_session: chat, name: "One",
      scene_json: { "elements" => [], "appState" => {}, "files" => {} },
      snapshot_kind: "manual", element_count: 0
    )

    expect(described_class.chat_payload_paths(chat_session: chat))
      .to eq(app_whiteboard_path: "/api/v1/app/chats/#{chat.id}/whiteboard")
    expect(described_class.chat_payload_counts(chat_session: chat))
      .to eq(whiteboard_snapshot_count: 1)
  end
end

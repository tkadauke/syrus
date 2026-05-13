require "rails_helper"

RSpec.describe Whiteboard do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "creates with an empty scene and version zero by default" do
    whiteboard = described_class.create!(chat_session: chat_session)

    expect(whiteboard.scene_json).to eq("elements" => [])
    expect(whiteboard.version).to eq(0)
    expect(whiteboard.last_edited_at).to be_nil
  end

  it "requires scene_json to be a hash" do
    whiteboard = described_class.new(chat_session: chat_session, scene_json: [])

    expect(whiteboard).not_to be_valid
    expect(whiteboard.errors[:scene_json]).to include("must be a hash")
  end

  it "requires scene_json to include an elements array" do
    missing_elements = described_class.new(chat_session: chat_session, scene_json: {})
    non_array_elements = described_class.new(chat_session: chat_session, scene_json: { "elements" => {} })

    expect(missing_elements).not_to be_valid
    expect(missing_elements.errors[:scene_json]).to include("must include an elements array")
    expect(non_array_elements).not_to be_valid
    expect(non_array_elements.errors[:scene_json]).to include("must include an elements array")
  end

  it "is destroyed with its chat session" do
    whiteboard = described_class.create!(chat_session: chat_session)

    expect { chat_session.destroy }.to change { described_class.where(id: whiteboard.id).count }.by(-1)
  end

  it "broadcasts the scene on the chat session whiteboard stream" do
    whiteboard = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [ { "id" => "box-1" } ] },
      version: 3
    )

    expect(Turbo::StreamsChannel).to receive(:broadcast_stream_to).with(
      "chat_session_#{chat_session.id}_whiteboard",
      content: { "elements" => [ { "id" => "box-1" } ], "version" => 3 }.to_json
    )

    whiteboard.broadcast_scene
  end
end

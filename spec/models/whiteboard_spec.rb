require "rails_helper"

RSpec.describe Whiteboard do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "creates with an empty scene and version zero by default" do
    whiteboard = described_class.create!(chat_session: chat_session)

    expect(whiteboard.scene_json).to eq("elements" => [], "appState" => {}, "files" => {})
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

  it "requires optional appState and files to be hashes" do
    bad_app_state = described_class.new(chat_session: chat_session, scene_json: { "elements" => [], "appState" => [] })
    bad_files = described_class.new(chat_session: chat_session, scene_json: { "elements" => [], "files" => [] })

    expect(bad_app_state).not_to be_valid
    expect(bad_app_state.errors[:scene_json]).to include("appState must be a hash")
    expect(bad_files).not_to be_valid
    expect(bad_files.errors[:scene_json]).to include("files must be a hash")
  end

  it "normalizes older element-only scenes" do
    whiteboard = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [ { "id" => "box-1" } ] }
    )

    expect(whiteboard.current_state).to eq(
      "elements" => [ { "id" => "box-1" } ],
      "appState" => {},
      "files" => {},
      "version" => 0
    )
  end

  it "strips non-serializable Excalidraw appState before serving a scene" do
    whiteboard = described_class.create!(
      chat_session: chat_session,
      scene_json: {
        "elements" => [],
        "appState" => {
          "viewBackgroundColor" => "#ffffff",
          "collaborators" => {},
          "selectedElementIds" => { "box-1" => true }
        }
      }
    )

    expect(whiteboard.current_state.fetch("appState")).to eq("viewBackgroundColor" => "#ffffff")
  end

  it "strips activeTool from appState so remote scene updates do not switch the user's active tool" do
    whiteboard = described_class.create!(
      chat_session: chat_session,
      scene_json: {
        "elements" => [],
        "appState" => {
          "viewBackgroundColor" => "#ffffff",
          "activeTool" => { "type" => "rectangle", "customType" => nil }
        }
      }
    )

    expect(whiteboard.current_state.fetch("appState")).to eq("viewBackgroundColor" => "#ffffff")
  end

  it "caps the scene element count" do
    whiteboard = described_class.new(
      chat_session: chat_session,
      scene_json: { "elements" => Array.new(described_class::MAX_ELEMENTS + 1) { |index| { "id" => "shape-#{index}" } } }
    )

    expect(whiteboard).not_to be_valid
    expect(whiteboard.errors[:scene_json]).to include(described_class.element_limit_message)
  end

  it "is destroyed with its chat session" do
    whiteboard = described_class.create!(chat_session: chat_session)

    expect { chat_session.destroy }.to change { described_class.where(id: whiteboard.id).count }.by(-1)
  end

  it "broadcasts an app event for the React chat renderer" do
    whiteboard = described_class.create!(
      chat_session: chat_session,
      scene_json: { "elements" => [ { "id" => "box-1" } ] },
      version: 3
    )

    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "whiteboard" ],
      payload: { "elements" => [ { "id" => "box-1" } ], "appState" => {}, "files" => {}, "version" => 3 }
    )

    whiteboard.broadcast_scene
  end
end

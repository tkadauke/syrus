require "rails_helper"

RSpec.describe "App API chat whiteboards", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(repository: repo, user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def whiteboard_path(chat_session) = "/api/v1/app/chats/#{chat_session.id}/whiteboard"
  def element(id) = { "id" => id, "type" => "rectangle" }

  describe "GET /api/v1/app/chats/:id/whiteboard" do
    it "returns the empty default state without creating a whiteboard" do
      expect {
        get whiteboard_path(chat), as: :json
      }.not_to change(Whiteboard, :count)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("scene_json" => { "elements" => [], "appState" => {}, "files" => {} }, "version" => 0)
    end

    it "returns the current whiteboard state" do
      chat.create_whiteboard!(
        scene_json: {
          "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ],
          "appState" => { "viewBackgroundColor" => "#ffffff" },
          "files" => { "file-1" => { "id" => "file-1", "dataURL" => "data:image/png;base64,abc" } }
        },
        version: 7
      )

      get whiteboard_path(chat), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "scene_json" => {
          "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ],
          "appState" => { "viewBackgroundColor" => "#ffffff" },
          "files" => { "file-1" => { "id" => "file-1", "dataURL" => "data:image/png;base64,abc" } }
        },
        "version" => 7
      )
    end

    it "blocks reads for chats owned by another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      other_chat = ChatSession.create!(repository: other_repo, user: other_user)
      other_chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "private-box" } ], "appState" => {}, "files" => {} },
        version: 4
      )

      get whiteboard_path(other_chat), as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("private-box")
    end
  end

  describe "PATCH /api/v1/app/chats/:id/whiteboard" do
    it "creates a missing whiteboard, updates matching versions, and emits UI updates" do
      elements = [ { "id" => "box-1", "type" => "rectangle", "x" => 12 } ]
      app_state = { "viewBackgroundColor" => "#ffffff" }
      files = { "file-1" => { "id" => "file-1", "dataURL" => "data:image/png;base64,abc" } }

      expect(AppEvents).to receive(:broadcast).with(
        user: user,
        type: "updated",
        resource: "chat",
        id: chat.id,
        changed: [ "whiteboard" ],
        payload: { "elements" => elements, "appState" => app_state, "files" => files, "version" => 1 }
      )

      expect {
        patch whiteboard_path(chat),
              params: { elements: elements, appState: app_state, files: files, expected_version: 0 },
              as: :json
      }.to change(Whiteboard, :count).by(1)

      whiteboard = chat.reload.whiteboard
      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("scene_json" => { "elements" => elements, "appState" => app_state, "files" => files }, "version" => 1)
      expect(whiteboard.scene_json).to eq("elements" => elements, "appState" => app_state, "files" => files)
      expect(whiteboard.version).to eq(1)
      expect(whiteboard.last_edited_at).to be_present
    end

    it "rejects updates beyond the element limit with a structured error" do
      elements = Array.new(Whiteboard::MAX_ELEMENTS + 1) { |index| element("shape-#{index}") }

      expect(AppEvents).not_to receive(:broadcast)

      expect {
        patch whiteboard_path(chat),
              params: { elements: elements, expected_version: 0 },
              as: :json
      }.not_to change(Whiteboard, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body).to eq(
        "error" => {
          "code" => "element_limit",
          "message" => Whiteboard.element_limit_message
        }
      )
    end

    it "returns conflict and the current state when the expected version is stale" do
      whiteboard = chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "current" } ] },
        version: 3
      )

      expect(AppEvents).not_to receive(:broadcast)

      patch whiteboard_path(chat),
            params: { elements: [ { "id" => "stale" } ], expected_version: 2 },
            as: :json

      expect(response).to have_http_status(:conflict)
      expect(parse_body).to eq("scene_json" => { "elements" => [ { "id" => "current" } ], "appState" => {}, "files" => {} }, "version" => 3)
      expect(whiteboard.reload.scene_json).to eq("elements" => [ { "id" => "current" } ])
      expect(whiteboard.version).to eq(3)
    end

    it "blocks access to chats owned by another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      other_chat = ChatSession.create!(repository: other_repo, user: other_user)

      patch whiteboard_path(other_chat),
            params: { elements: [], expected_version: 0 },
            as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end

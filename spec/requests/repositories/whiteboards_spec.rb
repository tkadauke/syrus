require "rails_helper"

RSpec.describe "Repository whiteboards", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(repository: repo, user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)

  describe "GET /repositories/:repository_id/chats/:chat_id/whiteboard" do
    it "returns the empty default state without creating a whiteboard" do
      expect {
        get repository_chat_whiteboard_path(repo, chat), as: :json
      }.not_to change(Whiteboard, :count)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("elements" => [], "version" => 0)
    end

    it "returns the current whiteboard state" do
      chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ] },
        version: 7
      )

      get repository_chat_whiteboard_path(repo, chat), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ],
        "version" => 7
      )
    end
  end

  describe "GET /repositories/:repository_id/whiteboard" do
    it "creates and returns an empty scene for the repository" do
      expect {
        get repository_whiteboard_path(repo), as: :json
      }.to change(RepositoryWhiteboard, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "scene_json" => { "elements" => [] },
        "version" => 0
      )
    end
  end

  describe "PATCH /repositories/:repository_id/chats/:chat_id/whiteboard" do
    it "creates a missing whiteboard, updates matching versions, and broadcasts the new state" do
      elements = [ { "id" => "box-1", "type" => "rectangle", "x" => 12 } ]

      expect(Turbo::StreamsChannel).to receive(:broadcast_stream_to).with(
        "chat_session_#{chat.id}_whiteboard",
        content: { "elements" => elements, "version" => 1 }.to_json
      )

      expect {
        patch repository_chat_whiteboard_path(repo, chat),
              params: { elements: elements, expected_version: 0 },
              as: :json
      }.to change(Whiteboard, :count).by(1)

      whiteboard = chat.reload.whiteboard
      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("elements" => elements, "version" => 1)
      expect(whiteboard.scene_json).to eq("elements" => elements)
      expect(whiteboard.version).to eq(1)
      expect(whiteboard.last_edited_at).to be_present
    end

    it "updates an existing whiteboard when the expected version matches" do
      whiteboard = chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "old" } ] },
        version: 14
      )
      elements = [ { "id" => "new", "type" => "ellipse" } ]
      allow(Turbo::StreamsChannel).to receive(:broadcast_stream_to)

      patch repository_chat_whiteboard_path(repo, chat),
            params: { elements: elements, expected_version: 14 },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("elements" => elements, "version" => 15)
      expect(whiteboard.reload.scene_json).to eq("elements" => elements)
      expect(whiteboard.version).to eq(15)
    end

    it "returns conflict and the current state when the expected version is stale" do
      whiteboard = chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "current" } ] },
        version: 3
      )

      expect(Turbo::StreamsChannel).not_to receive(:broadcast_stream_to)

      patch repository_chat_whiteboard_path(repo, chat),
            params: { elements: [ { "id" => "stale" } ], expected_version: 2 },
            as: :json

      expect(response).to have_http_status(:conflict)
      expect(parse_body).to eq("elements" => [ { "id" => "current" } ], "version" => 3)
      expect(whiteboard.reload.scene_json).to eq("elements" => [ { "id" => "current" } ])
      expect(whiteboard.version).to eq(3)
    end

    it "blocks access to repositories owned by another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      other_chat = ChatSession.create!(repository: other_repo, user: other_user)

      patch repository_chat_whiteboard_path(other_repo, other_chat),
            params: { elements: [], expected_version: 0 },
            as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /repositories/:repository_id/whiteboard" do
    it "persists elements and increments the version" do
      elements = [
        {
          id: "rect-1",
          type: "rectangle",
          x: 10,
          y: 20,
          width: 100,
          height: 80
        }
      ]

      patch repository_whiteboard_path(repo),
            params: { elements: elements, expected_version: 0 },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "scene_json" => { "elements" => elements.map(&:stringify_keys) },
        "version" => 1
      )

      get repository_whiteboard_path(repo), as: :json

      expect(parse_body).to eq(
        "scene_json" => { "elements" => elements.map(&:stringify_keys) },
        "version" => 1
      )
    end

    it "returns the current scene on a stale expected_version without overwriting" do
      whiteboard = repo.create_repository_whiteboard!(
        scene_json: { "elements" => [ { "id" => "current", "type" => "ellipse" } ] },
        version: 2
      )

      patch repository_whiteboard_path(repo),
            params: {
              elements: [ { id: "stale", type: "rectangle" } ],
              expected_version: 1
            },
            as: :json

      expect(response).to have_http_status(:conflict)
      expect(parse_body).to eq(
        "scene_json" => { "elements" => [ { "id" => "current", "type" => "ellipse" } ] },
        "version" => 2
      )
      expect(whiteboard.reload.elements).to eq([ { "id" => "current", "type" => "ellipse" } ])
    end
  end
end

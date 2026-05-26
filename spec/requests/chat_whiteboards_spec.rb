require "rails_helper"

# Chat whiteboards are intentionally scoped to a ChatSession. The retired
# repository-wide whiteboard endpoint is covered only as an unroutable path.
RSpec.describe "Chat whiteboards", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(repository: repo, user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def element(id) = { "id" => id, "type" => "rectangle" }

  describe "GET /chats/:chat_id/whiteboard" do
    it "returns the empty default state without creating a whiteboard" do
      expect {
        get chat_whiteboard_path(chat), as: :json
      }.not_to change(Whiteboard, :count)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("scene_json" => { "elements" => [] }, "version" => 0)
    end

    it "returns the current whiteboard state" do
      chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ] },
        version: 7
      )

      get chat_whiteboard_path(chat), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "scene_json" => { "elements" => [ { "id" => "rect-1", "type" => "rectangle" } ] },
        "version" => 7
      )
    end
  end

  describe "PATCH /chats/:chat_id/whiteboard" do
    it "creates a missing whiteboard, updates matching versions, and broadcasts the new state" do
      elements = [ { "id" => "box-1", "type" => "rectangle", "x" => 12 } ]

      expect(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to).with(
        "chat_session_#{chat.id}_whiteboard",
        hash_including(
          target: "chat_session_#{chat.id}_whiteboard_broadcast",
          partial: "chats/whiteboard_broadcast"
        )
      )

      expect {
        patch chat_whiteboard_path(chat),
              params: { elements: elements, expected_version: 0 },
              as: :json
      }.to change(Whiteboard, :count).by(1)

      whiteboard = chat.reload.whiteboard
      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("scene_json" => { "elements" => elements }, "version" => 1)
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
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to)

      patch chat_whiteboard_path(chat),
            params: { elements: elements, expected_version: 14 },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("scene_json" => { "elements" => elements }, "version" => 15)
      expect(whiteboard.reload.scene_json).to eq("elements" => elements)
      expect(whiteboard.version).to eq(15)
    end

    it "rejects updates beyond the element limit" do
      elements = Array.new(Whiteboard::MAX_ELEMENTS + 1) { |index| element("shape-#{index}") }

      expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_later_to)

      expect {
        patch chat_whiteboard_path(chat),
              params: { elements: elements, expected_version: 0 },
              as: :json
      }.not_to change(Whiteboard, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body).to eq("error" => Whiteboard.element_limit_message)
    end

    it "returns conflict and the current state when the expected version is stale" do
      whiteboard = chat.create_whiteboard!(
        scene_json: { "elements" => [ { "id" => "current" } ] },
        version: 3
      )

      expect(Turbo::StreamsChannel).not_to receive(:broadcast_replace_later_to)

      patch chat_whiteboard_path(chat),
            params: { elements: [ { "id" => "stale" } ], expected_version: 2 },
            as: :json

      expect(response).to have_http_status(:conflict)
      expect(parse_body).to eq("scene_json" => { "elements" => [ { "id" => "current" } ] }, "version" => 3)
      expect(whiteboard.reload.scene_json).to eq("elements" => [ { "id" => "current" } ])
      expect(whiteboard.version).to eq(3)
    end

    it "blocks access to chats owned by another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      other_chat = ChatSession.create!(repository: other_repo, user: other_user)

      patch chat_whiteboard_path(other_chat),
            params: { elements: [], expected_version: 0 },
            as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end

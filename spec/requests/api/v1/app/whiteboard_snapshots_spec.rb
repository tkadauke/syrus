require "rails_helper"

RSpec.describe "App API whiteboard snapshots", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(repository: repo, user: user) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def snapshots_path(chat_session) = "/api/v1/app/chats/#{chat_session.id}/whiteboard_snapshots"
  def snapshot_path(chat_session, snapshot) = "#{snapshots_path(chat_session)}/#{snapshot.id}"

  describe "GET /api/v1/app/chats/:chat_id/whiteboard_snapshots" do
    it "returns an empty list when the chat has no snapshots" do
      get snapshots_path(chat), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq("whiteboard_snapshots" => [])
    end

    it "returns snapshots for the chat newest first without scene JSON" do
      older = create_snapshot(
        chat_session: chat,
        name: "First save",
        snapshot_kind: "manual",
        element_count: 2,
        scene_json: { "elements" => [ { "id" => "a" }, { "id" => "b" } ], "appState" => {}, "files" => {} },
        created_at: Time.zone.local(2026, 6, 25, 14, 30, 0)
      )
      newer = create_snapshot(
        chat_session: chat,
        name: "Before clear - Jun 25 15:00",
        snapshot_kind: "auto_clear",
        element_count: 1,
        scene_json: { "elements" => [ { "id" => "c" } ], "appState" => {}, "files" => {} },
        created_at: Time.zone.local(2026, 6, 25, 15, 0, 0)
      )

      get snapshots_path(chat), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "whiteboard_snapshots" => [
          {
            "id" => newer.id,
            "name" => "Before clear - Jun 25 15:00",
            "snapshot_kind" => "auto_clear",
            "element_count" => 1,
            "created_at" => "2026-06-25T15:00:00Z"
          },
          {
            "id" => older.id,
            "name" => "First save",
            "snapshot_kind" => "manual",
            "element_count" => 2,
            "created_at" => "2026-06-25T14:30:00Z"
          }
        ]
      )
    end
  end

  describe "GET /api/v1/app/chats/:chat_id/whiteboard_snapshots/:id" do
    it "returns the full snapshot including scene JSON" do
      scene_json = {
        "elements" => [ { "id" => "box-1", "type" => "rectangle" } ],
        "appState" => { "viewBackgroundColor" => "#ffffff" },
        "files" => { "file-1" => { "id" => "file-1", "mimeType" => "image/png" } }
      }
      snapshot = create_snapshot(
        chat_session: chat,
        name: "Milestone",
        snapshot_kind: "manual",
        element_count: 1,
        scene_json: scene_json,
        created_at: Time.zone.local(2026, 6, 25, 16, 0, 0)
      )

      get snapshot_path(chat, snapshot), as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body).to eq(
        "id" => snapshot.id,
        "name" => "Milestone",
        "snapshot_kind" => "manual",
        "element_count" => 1,
        "created_at" => "2026-06-25T16:00:00Z",
        "scene_json" => scene_json
      )
    end

    it "returns not found when the snapshot does not exist" do
      get "#{snapshots_path(chat)}/999999", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns not found for a snapshot from another chat" do
      other_chat = ChatSession.create!(repository: repo, user: user)
      snapshot = create_snapshot(
        chat_session: other_chat,
        name: "Other chat",
        scene_json: { "elements" => [ { "id" => "private-box" } ], "appState" => {}, "files" => {} }
      )

      get snapshot_path(chat, snapshot), as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("private-box")
    end
  end

  def create_snapshot(attributes)
    WhiteboardSnapshot.create!(
      {
        chat_session: chat,
        name: "Snapshot",
        scene_json: { "elements" => [], "appState" => {}, "files" => {} },
        snapshot_kind: "manual",
        element_count: 0
      }.merge(attributes)
    )
  end
end

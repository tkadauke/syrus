require "rails_helper"

RSpec.describe "App API users", type: :request do
  let(:user) { Factories.user(first_name: "Marcus", last_name: "Cato") }

  def parse_body = JSON.parse(response.body)

  describe "GET /api/v1/app/users/invitable" do
    it "401s when signed out" do
      get "/api/v1/app/users/invitable"

      expect(response).to have_http_status(:unauthorized)
    end

    it "lists every other user, excluding the current user" do
      sign_in_as(user)
      other_user = Factories.user(first_name: "Cicero", last_name: nil)

      get "/api/v1/app/users/invitable"

      expect(response).to have_http_status(:ok)
      ids = parse_body.pluck("id")
      expect(ids).to include(other_user.id)
      expect(ids).not_to include(user.id)
      expect(parse_body).to include("id" => other_user.id, "name" => other_user.display_name)
    end

    it "additionally excludes participants of the given exclude_chat_id" do
      sign_in_as(user)
      already_in_chat = Factories.user
      not_in_chat = Factories.user
      chat = ChatSession.create!(user: user, conversation_kind: "group")
      chat.chat_participants.create!(user: already_in_chat, role: "member")

      get "/api/v1/app/users/invitable", params: { exclude_chat_id: chat.id }

      ids = parse_body.pluck("id")
      expect(ids).to include(not_in_chat.id)
      expect(ids).not_to include(already_in_chat.id)
      expect(ids).not_to include(user.id)
    end

    it "ignores exclude_chat_id for a chat the current user cannot access" do
      sign_in_as(user)
      other_owner = Factories.user
      other_chat = ChatSession.create!(user: other_owner)
      candidate = Factories.user

      get "/api/v1/app/users/invitable", params: { exclude_chat_id: other_chat.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body.pluck("id")).to include(candidate.id)
    end
  end
end

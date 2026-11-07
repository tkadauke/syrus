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
      expect(parse_body).to include(hash_including("id" => other_user.id, "name" => other_user.display_name))
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

    it "searches the directory and bounds the result size" do
      sign_in_as(user)
      matching = Factories.user(first_name: "Cornelia", last_name: "Africana", email_address: "cornelia@example.com")
      Factories.user(first_name: "Tullia", last_name: "Ciceronis")

      get "/api/v1/app/users/invitable", params: { q: "afric", limit: 1 }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to contain_exactly(hash_including("id" => matching.id))
    end

    it "defaults to a bounded first page" do
      sign_in_as(user)
      21.times { Factories.user }

      get "/api/v1/app/users/invitable"

      expect(parse_body.length).to eq(20)
    end
  end
end

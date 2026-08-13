require "rails_helper"

RSpec.describe "Chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /chats/:id" do
    it "serves the React app shell" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      get chat_path(chat)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not serve the React app shell for another user's chat" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
      other_chat = ChatSession.create!(user: other_user, repository: other_repo, title: "Private chat")

      get chat_path(other_chat)

      expect(response).to redirect_to(root_path)
      expect(response.body).not_to include('id="syrus-spa-root"')
    end
  end

  it "does not route the retired legacy HTML chat endpoints" do
    expect {
      Rails.application.routes.recognize_path("/chats/new", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats/new/legacy", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats/1/legacy", method: :get)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats/1/message", method: :post)
    }.to raise_error(ActionController::RoutingError)
    expect {
      Rails.application.routes.recognize_path("/chats/1/messages", method: :get)
    }.to raise_error(ActionController::RoutingError)
  end
end

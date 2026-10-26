require "rails_helper"

RSpec.describe "API: chat shares", type: :request do
  let(:owner) { Factories.user }
  let(:recipient) { Factories.user }
  let(:outsider) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Planning") }

  def body = JSON.parse(response.body)

  before do
    allow(AppEvents).to receive(:broadcast)
    repository.repository_memberships.create!(user: recipient, role: "read")
  end

  it "lets only the owner create and revoke a person share and notifies the recipient" do
    sign_in_as(recipient)
    post "/api/v1/app/chats/#{chat.id}/shares", params: { user_id: outsider.id }
    expect(response).to have_http_status(:not_found)

    sign_in_as(owner)
    post "/api/v1/app/chats/#{chat.id}/shares", params: { user_id: recipient.id }
    expect(response).to have_http_status(:created)
    share = chat.chat_shares.find_by!(target: recipient)
    expect(owner.notifications).to be_empty
    expect(recipient.notifications).to include(have_attributes(kind: "chat_mention", target_path: "/chats/#{chat.id}"))

    sign_in_as(recipient)
    delete "/api/v1/app/chats/#{chat.id}/shares/#{share.id}"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(owner)
    delete "/api/v1/app/chats/#{chat.id}/shares/#{share.id}"
    expect(response).to have_http_status(:ok)
    expect(recipient.accessible_chat_sessions).not_to include(chat)
  end

  it "scopes candidates to shared repositories or teams, while allowing an exact handle" do
    teammate = Factories.user
    team = Team.create!(name: "Shared team")
    team.team_memberships.create!(user: owner, role: "owner")
    team.team_memberships.create!(user: teammate, role: "member")
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}/shares"
    expect(body.fetch("candidates").map { |person| person.fetch("user_id") }).to contain_exactly(recipient.id, teammate.id)

    get "/api/v1/app/chats/#{chat.id}/shares", params: { q: "@#{outsider.handle}" }
    expect(body.fetch("candidates")).to contain_exactly(include("user_id" => outsider.id, "repository_access" => false))
  end

  it "removes shares when either the chat or person is deleted" do
    chat_share = ChatShare.create!(chat_session: chat, target: recipient, shared_by_user: owner)
    chat.destroy!
    expect(ChatShare.exists?(chat_share.id)).to be(false)

    another_chat = ChatSession.create!(user: owner)
    person_share = ChatShare.create!(chat_session: another_chat, target: recipient, shared_by_user: owner)
    recipient.destroy!
    expect(ChatShare.exists?(person_share.id)).to be(false)
  end
end

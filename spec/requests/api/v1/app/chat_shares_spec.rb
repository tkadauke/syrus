require "rails_helper"

RSpec.describe "API: chat shares", type: :request do
  let(:owner) { Factories.user(name: "Owner") }
  let(:recipient) { Factories.user(name: "Recipient") }
  let(:outsider) { Factories.user(name: "Outsider") }
  let(:chat) { ChatSession.create!(user: owner, title: "Shared plans") }

  def prepare_chat_search
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
  end

  it "lets a recipient read the full chat API but never post" do
    prepare_chat_search
    chat.messages.create!(role: "assistant", content: { "text" => "live history", "attachments" => [ { "name" => "notes.txt" } ] })
    share = ChatShare.create!(chat_session: chat, target: recipient, shared_by_user: owner)
    sign_in_as(recipient)

    get "/api/v1/app/chats/#{chat.id}"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("chat", "read_only")).to be(true)
    expect(response.parsed_body.fetch("messages").to_s).to include("live history", "notes.txt")

    get "/api/v1/app/chats"
    shared_group = response.parsed_body.fetch("groups").find { |group| group.fetch("key") == "shared-with-me" }
    expect(shared_group.fetch("label")).to eq("Shared with me")
    expect(shared_group.fetch("chats").first).to include("id" => chat.id, "read_only" => true)

    get "/api/v1/app/chats/search"
    expect(response.parsed_body.fetch("results").pluck("chat_session_id")).to include(chat.id)

    get "/api/v1/app/chats/search/messages", params: { chat_session_id: chat.id, q: "live" }
    expect(response).to have_http_status(:ok)

    post "/api/v1/app/chats/#{chat.id}/message", params: { chat_message: { message: "no" } }
    expect(response).to have_http_status(:forbidden)
    expect(chat.messages.count).to eq(1)

    share.destroy!
    get "/api/v1/app/chats/#{chat.id}"
    expect(response).to have_http_status(:not_found)
  end

  it "keeps outsiders from the chat list, API, and search" do
    ChatShare.create!(chat_session: chat, target: recipient, shared_by_user: owner)
    sign_in_as(outsider)

    get "/api/v1/app/chats"
    expect(response.parsed_body.fetch("groups").flat_map { |group| group.fetch("chats") }.map { |row| row.fetch("id") }).not_to include(chat.id)
    get "/api/v1/app/chats/#{chat.id}"
    expect(response).to have_http_status(:not_found)
    get "/api/v1/app/chats/search", params: { q: "Shared" }
    expect(response.parsed_body.fetch("results")).to be_empty
    get "/api/v1/app/chats/search/messages", params: { chat_session_id: chat.id, q: "Shared" }
    expect(response).to have_http_status(:not_found)
  end

  it "allows only the owner to create and revoke shares" do
    sign_in_as(owner)
    post "/api/v1/app/chats/#{chat.id}/shares", params: { user_id: recipient.id }
    expect(response).to have_http_status(:created)
    share_id = response.parsed_body.fetch("shares").first.fetch("id")

    delete "/api/v1/app/chats/#{chat.id}/shares/#{share_id}"
    expect(response).to have_http_status(:ok)
    expect(chat.chat_shares).to be_empty
  end

  it "paginates the Shared with me group with the ordinary cursor endpoint" do
    recipient.update!(recent_chats_group_size: 5)
    shared_chats = 7.times.map do |index|
      session = ChatSession.create!(user: owner, title: "Shared #{index}", last_message_at: (index + 1).hours.ago)
      session.update_columns(created_at: session.last_message_at, updated_at: session.last_message_at)
      ChatShare.create!(chat_session: session, target: recipient, shared_by_user: owner)
      session
    end
    sign_in_as(recipient)

    get "/api/v1/app/chats"
    group = response.parsed_body.fetch("groups").find { |candidate| candidate.fetch("key") == "shared-with-me" }
    expect(group.fetch("chats").pluck("id")).to eq(shared_chats.first(5).map(&:id))
    expect(group.fetch("has_more")).to be(true)

    get "/api/v1/app/chats/more", params: {
      group_by: "shared",
      group_key: "shared-with-me",
      before_id: group.fetch("chats").last.fetch("id"),
      per_group: 5
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("chats").pluck("id")).to eq(shared_chats.last(2).map(&:id))
    expect(response.parsed_body.fetch("has_more")).to be(false)
  end
end

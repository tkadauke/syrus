require "rails_helper"

RSpec.describe "API: coworkers", type: :request do
  let(:owner) { Factories.user }

  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "lists only the signed-in owner's coworkers with Syrus pinned separately" do
    owner.update!(agent_provider: "codex", codex_auth_mode: "api_key", codex_api_key: "secret")
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    other = Factories.user(email_address: "other@example.com")
    Coworkers::Coworker.create!(owner_user: other, name: "Hidden", handle: "hidden", workspace_repo: "https://github.com/acme/other.git")
    sign_in_as(owner)

    get "/api/v1/app/coworkers"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("syrus", "built_in")).to be(true)
    expect(body.fetch("coworkers")).to contain_exactly(include("id" => mine.id, "handle" => "maya"))
    expect(body.fetch("model_options")).to include(
      include("provider" => "codex", "models" => include(include("id" => AgentProviders::Codex.available_models.first.id)))
    )
  end

  it "groups coworker chats and includes their appearance in the chat list" do
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git", avatar_key: "comet")
    chat = ChatSession.create!(user: owner, title: "Maya")
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    sign_in_as(owner)

    get "/api/v1/app/chats"

    group = JSON.parse(response.body).fetch("groups").find { |candidate| candidate["key"] == "coworkers" }
    expect(group.fetch("chats")).to contain_exactly(include("id" => chat.id, "agent_appearance" => include("name" => "Maya", "avatar_key" => "comet")))
  end

  it "creates side chats in the coworker's Phase 1 home-branch workspace" do
    repository = Factories.repository(user: owner, owner: "acme", name: "workspace")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url,
      chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
    sign_in_as(owner)

    expect { post "/api/v1/app/coworkers/#{coworker.id}/chats" }.to change(Coworkers::Chat.where(role: "side"), :count).by(1)

    expect(response).to have_http_status(:created)
    chat = coworker.coworker_chats.find_by!(role: "side").chat_session
    expect(chat).to have_attributes(
      repository: repository, chat_provider: "codex", chat_model: "gpt-6.1-sol", chat_effort: "high"
    )
  end

  it "offers only the owner's coworkers as typed read-only share targets" do
    mine = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    other_owner = Factories.user(email_address: "other-owner@example.com")
    hidden = Coworkers::Coworker.create!(owner_user: other_owner, name: "Hidden", handle: "hidden", workspace_repo: "https://github.com/acme/other.git")
    chat = ChatSession.create!(user: owner, title: "Plans")
    sign_in_as(owner)

    get "/api/v1/app/chats/#{chat.id}/share_candidates"
    expect(response.parsed_body.fetch("targets")).to include(include("target_type" => "Coworkers::Coworker", "target_id" => mine.id, "kind" => "coworker"))
    expect(response.parsed_body.fetch("targets")).not_to include(include("target_id" => hidden.id, "kind" => "coworker"))

    post "/api/v1/app/chats/#{chat.id}/shares", params: { target_type: "Coworkers::Coworker", target_id: mine.id }
    expect(response).to have_http_status(:created)
    expect(chat.chat_shares.find_by!(target: mine).shared_by_user).to eq(owner)

    post "/api/v1/app/chats/#{chat.id}/shares", params: { target_type: "Coworkers::Coworker", target_id: hidden.id }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "badges and filters coworker chats on chat and global search" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: "https://github.com/acme/workspace.git")
    coworker_chat = ChatSession.create!(user: owner, title: "Maya")
    syrus_chat = ChatSession.create!(user: owner, title: "Syrus")
    Coworkers::Chat.create!(coworker: coworker, chat_session: coworker_chat, role: "main")
    message = coworker_chat.messages.create!(role: "user", content: { "text" => "calendar needle" })
    syrus_chat.messages.create!(role: "user", content: { "text" => "engineering needle" })
    ChatMessageSearchIndex.insert(message)
    sign_in_as(owner)

    get "/api/v1/app/filters/schema", params: { subject: "chat_message" }
    coworker_field = response.parsed_body.fetch("fields").find { |field| field.fetch("field") == "coworker_id" }
    expect(coworker_field.fetch("values")).to include({ "value" => "syrus", "label" => "Syrus" }, { "value" => coworker.id.to_s, "label" => "Maya" })

    get "/api/v1/app/chats/search", params: { coworker_id: coworker.id }
    expect(response.parsed_body.fetch("results")).to contain_exactly(
      include("chat_session_id" => coworker_chat.id, "badges" => [ { "kind" => "coworker", "id" => coworker.id, "name" => "Maya" } ])
    )

    filter = Filters::QueryParam.encode("and" => [ { "field" => "coworker_id", "op" => "is", "value" => coworker.id } ])
    get "/api/v1/app/search", params: { query: "calendar", q: filter, types: [ "chat" ] }
    expect(response.parsed_body.fetch("results")).to contain_exactly(
      include("id" => message.id, "badges" => [ { "kind" => "coworker", "id" => coworker.id, "name" => "Maya" } ])
    )
  end

  it "removes the routes and sidebar contribution when the plugin is disabled" do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: false)
    sign_in_as(owner)

    get "/api/v1/app/coworkers"
    expect(response).to have_http_status(:not_found)
    expect(Coworkers::SidebarPages.sidebar_pages).to be_present
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).not_to include(Coworkers::SidebarPages)
  end
end

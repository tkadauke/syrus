require "rails_helper"

RSpec.describe "API: /api/v1/admin/chats", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { admin; Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }
  let(:repository) { Factories.repository(user: admin, owner: "tkadauke", name: "syrus-test") }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  before { admin }

  describe "auth" do
    let!(:chat) { ChatSession.create!(user: admin, title: "Private planning chat") }

    it "401s without an Authorization header" do
      get "/api/v1/admin/chats/#{chat.id}"

      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "403s when the token belongs to a non-admin user" do
      get "/api/v1/admin/chats/#{chat.id}", headers: auth(non_admin_token)

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("forbidden")
    end
  end

  describe "GET /api/v1/admin/chats" do
    it "lists recent chats with user, repository, usage, and message counts" do
      older = ChatSession.create!(user: admin, title: "Older", last_message_at: 2.days.ago)
      newer = ChatSession.create!(
        user: admin,
        repository: repository,
        title: "Investigate chat agents",
        last_message_at: 1.hour.ago,
        cumulative_input_tokens: 1000,
        cumulative_output_tokens: 250,
        cumulative_cost_usd: 0.123456
      )
      newer.messages.create!(role: "user", content: { "text" => "Why is the agent stuck?" })
      ChatSession.create!(user: non_admin, title: "Other user", last_message_at: 30.minutes.ago)

      get "/api/v1/admin/chats", headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body).to include("total" => 3, "page" => 1, "per" => 50)
      expect(body["chats"].map { |chat| chat["id"] }).to include(newer.id, older.id)

      row = body["chats"].find { |chat| chat["id"] == newer.id }
      expect(row).to include(
        "title" => "Investigate chat agents",
        "messages_count" => 1,
        "cumulative_input_tokens" => 1000,
        "cumulative_output_tokens" => 250,
        "cumulative_cost_usd" => 0.123456
      )
      expect(row.dig("user", "email_address")).to eq(admin.email_address)
      expect(row["repositories"]).to contain_exactly(include("slug" => "tkadauke/syrus-test"))
    end

    it "filters by repository and user email substring" do
      other_user = Factories.user(email_address: "someone@example.com")
      other_repo = Factories.repository(user: admin, owner: "tkadauke", name: "other")
      other_user_repo = Factories.repository(user: other_user, owner: "tkadauke", name: "someone-fork")
      matching = ChatSession.create!(user: admin, repository: repository, title: "Matching")
      ChatSession.create!(user: admin, repository: other_repo, title: "Wrong repo")
      ChatSession.create!(user: other_user, repository: other_user_repo, title: "Wrong user")

      get "/api/v1/admin/chats",
          params: { repo: "tkadauke/syrus-test", user: "user-" },
          headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      expect(parse_body["chats"].map { |chat| chat["id"] }).to eq([ matching.id ])
    end
  end

  describe "GET /api/v1/admin/chats/:id" do
    it "returns raw paginated chat messages with tool calls, bookmarks, proposals, and attachments" do
      chat = ChatSession.create!(user: admin, repository: repository, title: "Whiteboard help")
      proposal = ChatProposal.create!(
        chat_session: chat,
        repository: repository,
        kind: "job",
        slug: "fix-whiteboard",
        title: "Fix whiteboard",
        body: "Make the whiteboard easier for agents."
      )
      first = chat.messages.create!(role: "user", content: { "text" => "Can you see the whiteboard?" })
      bookmark = first.bookmarks.create!(label: "Whiteboard check", kind: "topic")
      tool_use = chat.messages.create!(
        role: "tool_use",
        tool_name: "mcp__syrus-chat-sidecar__read_scene",
        tool_use_id: "toolu_1",
        content: { "input" => {} }
      )
      tool_result = chat.messages.create!(
        role: "tool_result",
        tool_use_id: "toolu_1",
        content: { "result" => [ { "type" => "text", "text" => "{\"elements\":[]}" } ] }
      )
      assistant = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "I can see it." })

      get "/api/v1/admin/chats/#{chat.id}", params: { per: 3 }, headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body).to include(
        "id" => chat.id,
        "title" => "Whiteboard help",
        "messages_count" => 4
      )
      expect(body["attachments"]).to contain_exactly(include("type" => "Repository", "label" => "tkadauke/syrus-test"))
      expect(body["bookmarks"]).to contain_exactly(include(
        "id" => bookmark.id,
        "label" => "Whiteboard check",
        "message_id" => first.id,
        "anchor" => "message-#{first.id}"
      ))
      expect(body["proposals"]).to contain_exactly(include(
        "id" => proposal.id,
        "slug" => "fix-whiteboard",
        "kind" => "job",
        "repository" => "tkadauke/syrus-test"
      ))
      expect(body["messages_page"]).to include(
        "before" => nil,
        "count" => 3,
        "per" => 3,
        "has_more_older" => true
      )
      expect(body["messages"].map { |message| message["id"] }).to eq([ tool_use.id, tool_result.id, assistant.id ])
      expect(body["messages"].first).to include(
        "role" => "tool_use",
        "tool_name" => "mcp__syrus-chat-sidecar__read_scene",
        "tool_use_id" => "toolu_1",
        "content" => { "input" => {} }
      )
      expect(body["messages"].second).to include(
        "role" => "tool_result",
        "tool_use_id" => "toolu_1",
        "content" => { "result" => [ { "type" => "text", "text" => "{\"elements\":[]}" } ] }
      )
      expect(body["messages"].third.dig("proposal", "id")).to eq(proposal.id)

      get "/api/v1/admin/chats/#{chat.id}", params: { before: tool_use.id, per: 3 }, headers: auth(admin_token)

      expect(response).to have_http_status(:ok)
      older_body = parse_body
      expect(older_body["messages_page"]).to include(
        "before" => tool_use.id,
        "count" => 1,
        "has_more_older" => false
      )
      expect(older_body["messages"].map { |message| message["id"] }).to eq([ first.id ])
    end
  end
end

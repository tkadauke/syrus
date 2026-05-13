require "rails_helper"

RSpec.describe "Repository chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /repositories/:repository_id/chats" do
    it "renders an empty new-chat view without persisting a ChatSession" do
      expect {
        get repository_chats_path(repo)
      }.not_to change(ChatSession, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Chat — Repository")
      expect(response.body).to include("Start a chat with this repository.")
      expect(response.body).to include("Tokens:")
    end

    it "renders the Claude-only provider notice for Codex users" do
      user.update!(
        agent_provider: "codex",
        codex_auth_mode: "api_key",
        codex_api_key: "sk-test"
      )

      get repository_chats_path(repo)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Chat requires Claude.")
      expect(response.body).to include("v1 is Claude-only")
      expect(response.body).to include(edit_credentials_path)
      expect(response.body).not_to include("Start a chat with this repository.")
      expect(response.body).not_to include("New chat")
      expect(response.body).not_to include("name=\"chat_message[text]\"")
    end

    it "renders the Claude credential onboarding notice when the token is missing" do
      user.update!(claude_oauth_token: nil)

      get repository_chats_path(repo)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Claude credentials are required.")
      expect(response.body).to include(edit_credentials_path)
      expect(response.body).not_to include("Start a chat with this repository.")
      expect(response.body).not_to include("New chat")
      expect(response.body).not_to include("name=\"chat_message[text]\"")
    end

    it "renders the newest chat by last_message_at" do
      older = ChatSession.create!(repository: repo, user: user, last_message_at: 2.hours.ago)
      older.messages.create!(role: "assistant", content: { "text" => "Old answer" })
      newer = ChatSession.create!(
        repository: repo,
        user: user,
        cumulative_input_tokens: 12_400,
        cumulative_output_tokens: 3_200,
        cumulative_cost_usd: 0.012345,
        last_message_at: 1.hour.ago
      )
      newer.messages.create!(role: "assistant", content: { "text" => "Newest answer" })

      get repository_chats_path(repo)

      expect(response.body).to include("Newest answer")
      expect(response.body).not_to include("Old answer")
      expect(response.body).to include("12.4k in")
      expect(response.body).to include("3.2k out")
      expect(response.body).to include("$0.0123")
      expect(response.body).to include("chat_session_#{newer.id}_messages")
      expect(response.body).to include("Refresh repo")
      expect(response.body).to include("Reset workspace")
    end

    it "disables compose while the latest user message has no response" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      chat.messages.create!(role: "user", content: { "text" => "Ping" })

      get repository_chats_path(repo)

      expect(response.body).to include('data-chat-turn-in-flight-value="true"')
      expect(response.body).to include("disabled")
      expect(response.body).to include("Stop")
    end

    it "renders tool rows with proposal links" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)
      proposal = ChatProposal.create!(
        chat_session: chat,
        slug: "auth-map",
        title: "Map auth flow",
        body: "Trace the auth flow."
      )
      chat.messages.create!(
        role: "tool_result",
        tool_name: "propose_issue",
        proposal: proposal,
        content: { "slug" => "auth-map", "state" => "pending" }
      )

      get repository_chats_path(repo)

      expect(response.body).to include("propose_issue")
      expect(response.body).to include("Proposal ##{proposal.id} created (pending)")
      expect(response.body).to include(repository_proposals_path(repo))
    end
  end

  describe "POST /repositories/:repository_id/chats" do
    it "shows an ephemeral new chat for an empty New chat post" do
      expect {
        post repository_chats_path(repo)
      }.not_to change(ChatSession, :count)

      expect(response).to redirect_to(repository_chats_path(repo, new_chat: "1"))
    end

    it "creates the chat, first user message, and enqueues a turn" do
      expect {
        post repository_chats_path(repo), params: { chat_message: { text: "Map the auth flow" } }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = repo.chat_sessions.last
      message = chat.messages.last
      expect(chat.user).to eq(user)
      expect(chat.last_message_at).to be_present
      expect(message.role).to eq("user")
      expect(message.content).to eq("text" => "Map the auth flow")
      expect(response).to redirect_to(repository_chats_path(repo))
    end

    it "creates a seeded docs-maintenance chat from a template" do
      expect {
        post repository_chats_path(repo), params: { chat_template: "docs_maintenance" }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = repo.chat_sessions.last
      message = chat.messages.last
      expect(chat.title).to include("Review roadmap and planning documentation")
      expect(message.content.fetch("text")).to include("ROADMAP.md")
      expect(message.content.fetch("text")).to include("Discover Markdown files across the repository")
      expect(message.content.fetch("text")).to include("docs/plans/complete/")
      expect(message.content.fetch("text")).to include("propose_issue")
      expect(response).to redirect_to(repository_chats_path(repo))
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/message" do
    it "appends a user message to an existing chat and enqueues a turn" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: 1.day.ago)

      expect {
        post repository_chat_message_path(repo, chat), params: { chat_message: { text: "Now inspect proposals" } }
      }.to change { chat.messages.count }.by(1)
        .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      expect(chat.reload.last_message_at).to be > 1.minute.ago
      expect(chat.messages.last.content).to eq("text" => "Now inspect proposals")
      expect(response).to redirect_to(repository_chats_path(repo))
    end

    it "rejects blank messages" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_message_path(repo, chat), params: { chat_message: { text: "  " } }
      }.not_to change(ChatMessage, :count)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:alert]).to eq("Message cannot be blank.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/stop" do
    it "sets the stop flag on the chat session" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      post repository_chat_stop_path(repo, chat)

      expect(chat.reload.stop_requested_at).to be_present
      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Stop requested.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/refresh" do
    it "enqueues a refresh workspace job" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_refresh_path(repo, chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :refresh)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Repository refresh queued.")
    end
  end

  describe "POST /repositories/:repository_id/chats/:id/reset" do
    it "enqueues a reset workspace job" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_reset_path(repo, chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(repo.id, action: :reset)

      expect(response).to redirect_to(repository_chats_path(repo))
      expect(flash[:notice]).to eq("Workspace reset queued.")
    end
  end
end

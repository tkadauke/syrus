require "rails_helper"

RSpec.describe "Repository chat redirects", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /repositories/:repository_id/chats" do
    it "redirects the latest repository chat to its top-level chat page" do
      older = ChatSession.create!(repository: repo, user: user, last_message_at: 2.hours.ago)
      newer = ChatSession.create!(repository: repo, user: user, last_message_at: 1.hour.ago)

      get repository_chats_path(repo)

      expect(response).to redirect_to(chat_path(newer))
      expect(older.reload.attached_repositories).to contain_exactly(repo)
      expect(newer.reload.attached_repositories).to contain_exactly(repo)
    end

    it "creates a top-level chat with the repository attached when no chat exists" do
      expect {
        get repository_chats_path(repo)
      }.to change(ChatSession, :count).by(1)

      chat = ChatSession.last
      expect(response).to redirect_to(chat_path(chat))
      expect(chat.attached_repositories).to contain_exactly(repo)
    end
  end

  describe "POST /repositories/:repository_id/chats" do
    it "creates an attached chat and redirects to the top-level chat" do
      expect {
        post repository_chats_path(repo), params: { chat_message: { text: "Map the auth flow" } }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = ChatSession.last
      expect(chat.attached_repositories).to contain_exactly(repo)
      expect(response).to redirect_to(chat_path(chat))
    end
  end

  describe "legacy member actions" do
    it "posts messages and redirects to the top-level chat" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: 1.day.ago)

      expect {
        post repository_chat_message_path(repo, chat), params: { chat_message: { text: "Now inspect proposals" } }
      }.to change { chat.messages.count }.by(1)
        .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      expect(response).to redirect_to(chat_path(chat))
    end

    it "keeps workspace actions available and redirects to the top-level chat" do
      chat = ChatSession.create!(repository: repo, user: user, last_message_at: Time.current)

      expect {
        post repository_chat_refresh_path(repo, chat)
      }.to have_enqueued_job(ChatWorkspaceJob).with(chat.id, action: :refresh)

      expect(response).to redirect_to(chat_path(chat))
    end
  end
end

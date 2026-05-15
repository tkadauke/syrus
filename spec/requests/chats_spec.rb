require "rails_helper"

RSpec.describe "Chats", type: :request do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  describe "GET /chats/new" do
    it "renders the new top-level chat form without creating a chat" do
      repo

      expect {
        get new_chat_path
      }.not_to change(ChatSession, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New chat")
      expect(response.body).to include("Create chat")
      expect(response.body).to include(repo.slug)
    end
  end

  describe "POST /chats" do
    it "creates a fresh chat with an optional repository attachment" do
      expect {
        post chats_path, params: { repository_id: repo.id }
      }.to change(ChatSession, :count).by(1)

      chat = ChatSession.last
      expect(chat.user).to eq(user)
      expect(chat.attached_repositories).to contain_exactly(repo)
      expect(response).to redirect_to(chat_path(chat))
    end

    it "creates the first message and enqueues a turn when a repository is attached" do
      expect {
        post chats_path, params: { repository_id: repo.id, chat_message: { text: "Map auth" } }
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob)

      chat = ChatSession.last
      expect(chat.messages.last.content).to eq("text" => "Map auth")
      expect(response).to redirect_to(chat_path(chat))
    end
  end

  describe "GET /chats/:id" do
    it "renders the chat page with attachment sidebar and in-scope documents" do
      document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Launch notes",
        google_docs_url: "https://docs.google.com/document/d/launch/edit"
      )
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)

      get chat_path(chat)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Attachments")
      expect(response.body).to include("Add attachment")
      expect(response.body).to include(repo.slug)
      expect(response.body).to include(document.title)
      expect(response.body).to include(chat_attachments_path(chat))
      expect(response.body).to include(chat_message_path(chat))
      expect(response.body).to include(chat_whiteboard_path(chat))
    end

    it "renders only the latest page of messages and exposes the older-message endpoint" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: Time.current)
      40.times { |i| chat.messages.create!(role: "user", content: { "text" => "msg-#{i}" }) }

      get chat_path(chat)

      message_ids = response.body.scan(/id="chat_message_(\d+)"/).flatten.map(&:to_i)
      expect(message_ids).to eq(chat.messages.order(:id).last(30).pluck(:id))
      expect(response.body).to include('data-chat-has-more-older-value="true"')
      expect(response.body).to include(chat_messages_path(chat))
    end
  end

  describe "POST /chats/:id/message" do
    it "appends a user message to an existing top-level chat and enqueues a turn" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.day.ago)

      expect {
        post chat_message_path(chat), params: { chat_message: { text: "Now inspect proposals" } }
      }.to change { chat.messages.count }.by(1)
        .and have_enqueued_job(ChatTurnJob).with(chat.id, kind_of(Integer))

      expect(chat.reload.last_message_at).to be > 1.minute.ago
      expect(response).to redirect_to(chat_path(chat))
    end
  end

  describe "attachment management" do
    it "adds and removes attachments" do
      chat = ChatSession.create!(user: user)

      post chat_attachments_path(chat), params: { attachable_type: "Repository", attachable_id: repo.id }

      expect(response).to redirect_to(chat_path(chat))
      attachment = chat.reload.chat_attachments.sole
      expect(attachment.attachable).to eq(repo)

      delete chat_attachment_path(chat, attachment)

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.chat_attachments).to be_empty
    end

    it "adds a repository document attachment from the Document picker" do
      document = repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Design notes",
        google_docs_url: "https://docs.google.com/document/d/design/edit"
      )
      chat = ChatSession.create!(user: user)

      post chat_attachments_path(chat), params: { attachable_type: "Document", attachable_id: document.id }

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.attached_repository_documents).to contain_exactly(document)
    end
  end

  describe "legacy repository chat URL" do
    it "redirects to the top-level chat and keeps the repository attached" do
      chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.hour.ago)

      get repository_chats_path(repo)

      expect(response).to redirect_to(chat_path(chat))
      expect(chat.reload.attached_repositories).to contain_exactly(repo)
    end

    it "creates an attached chat when the old repository chat URL has no session yet" do
      expect {
        get repository_chats_path(repo)
      }.to change(ChatSession, :count).by(1)

      chat = ChatSession.last
      expect(response).to redirect_to(chat_path(chat))
      expect(chat.attached_repositories).to contain_exactly(repo)
    end
  end
end

require "rails_helper"

RSpec.describe "App API job chats", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repo, issue_number: 42) }

  def parse_body = JSON.parse(response.body)
  def path(job_record) = "/api/v1/app/jobs/#{job_record.id}/start_chat"

  before do
    allow(User).to receive(:chat_providers).and_return(%w[claude])
  end

  context "as the job's creator" do
    before { sign_in_as(user) }

    it "starts a new chat and permanently attaches the job to it" do
      expect {
        post path(job), as: :json
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTitleJob).with(kind_of(Integer), kind_of(Integer))
        .and have_enqueued_job(ChatTurnJob).with(kind_of(Integer), kind_of(Integer))

      expect(response).to have_http_status(:ok)
      chat = ChatSession.last
      message = chat.messages.sole
      expect(chat.user_id).to eq(user.id)
      expect(chat.attached_repositories).to include(repo)
      expect(chat.attached_jobs).to contain_exactly(job)
      expect(chat).to be_turn_in_flight
      expect(message.role).to eq("user")
      expect(message.sender_user_id).to eq(user.id)
      expect(message.content["text"]).to eq("Context: discuss JOB-#{job.id}.")
      expect(job.reload.discussion_chat).to eq(chat)
      expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
      expect(ChatTitleJob).to have_been_enqueued.with(chat.id, message.id)
      expect(ChatTurnJob).to have_been_enqueued.with(chat.id, message.id)
    end

    it "reuses the existing discussion chat without injecting a duplicate context turn" do
      existing_chat = ChatSession.create!(user: user, repository: repo)
      job.chat_attachments.create!(chat_session: existing_chat)

      expect {
        post path(job), as: :json
      }.not_to change(ChatMessage, :count)
      expect(ChatSession.count).to eq(1)

      expect(ChatTurnJob).not_to have_been_enqueued
      expect(parse_body["redirect_to"]).to eq("/chats/#{existing_chat.id}")
    end

    it "creates a fresh chat instead of reusing proposal-lineage or recent repository chats" do
      proposal_chat = ChatSession.create!(user: user, repository: repo, last_message_at: 2.days.ago)
      recent_chat = ChatSession.create!(user: user, repository: repo, last_message_at: 1.hour.ago)
      ChatProposal.create!(
        chat_session: proposal_chat,
        repository: repo,
        job: job,
        state: "confirmed",
        confirmed_at: Time.current,
        kind: "job",
        slug: "proposal-chat",
        title: "Proposal chat",
        body: "Body"
      )

      expect {
        post path(job), as: :json
      }.to change(ChatSession, :count).by(1)

      chat = job.reload.discussion_chat
      expect(chat).to be_present
      expect(chat).not_to eq(proposal_chat)
      expect(chat).not_to eq(recent_chat)
      expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
    end

    it "adds a supplied discussion message to an existing job chat and wakes it" do
      existing_chat = ChatSession.create!(user: user, repository: repo)
      job.chat_attachments.create!(chat_session: existing_chat)

      expect {
        post path(job), params: { message: "Revision: abc123\nLocation: app/models/widget.rb:12\n\nComment:\nPlease check this." }, as: :json
      }.to change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob).with(existing_chat.id, kind_of(Integer))

      expect(response).to have_http_status(:ok)
      message = existing_chat.messages.sole
      expect(message.content["text"]).to eq(<<~TEXT.strip)
        Context: discuss JOB-#{job.id}.

        Revision: abc123
        Location: app/models/widget.rb:12

        Comment:
        Please check this.
      TEXT
      expect(parse_body["redirect_to"]).to eq("/chats/#{existing_chat.id}")
    end

    it "adds a supplied prompt to a fresh job chat after the job reference" do
      expect {
        post path(job), params: { message: "Please explain what is blocked." }, as: :json
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage, :count).by(1)
        .and have_enqueued_job(ChatTurnJob).with(kind_of(Integer), kind_of(Integer))

      message = job.reload.discussion_chat.messages.sole
      expect(message.content["text"]).to eq(<<~TEXT.strip)
        Context: discuss JOB-#{job.id}.

        Please explain what is blocked.
      TEXT
    end

    it "returns 404 for a job in a repository the user cannot access" do
      other_repo = Factories.repository(user: Factories.user, owner: "globex", name: "private")
      other_job = Factories.job_record(repository: other_repo, issue_number: 99)

      post path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  context "as a repository member who did not create the job" do
    it "allows a write-tier member to start the chat" do
      job # ensure the job's owner is created first -- the first User in a
      # test example is auto-promoted to admin, which would make this
      # test pass for the wrong reason
      writer = Factories.user(admin: false)
      RepositoryMembership.create!(repository: repo, user: writer, role: "write")
      sign_in_as(writer)

      post path(job), as: :json

      expect(response).to have_http_status(:ok)
      chat = ChatSession.last
      expect(chat.user_id).to eq(writer.id)
      expect(job.reload.discussion_chat).to eq(chat)
    end

    it "forbids a read-only member from starting the chat" do
      job # see note above
      reader = Factories.user(admin: false)
      RepositoryMembership.create!(repository: repo, user: reader, role: "read")
      sign_in_as(reader)

      expect {
        post path(job), as: :json
      }.not_to change(ChatSession, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end
end

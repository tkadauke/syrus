require "rails_helper"

RSpec.describe "App API job chats", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repo, issue_number: 42) }

  def parse_body = JSON.parse(response.body)
  def path(job_record) = "/api/v1/app/jobs/#{job_record.id}/start_chat"

  context "as the job's creator" do
    before { sign_in_as(user) }

    it "starts a new chat and permanently attaches the job to it" do
      expect {
        post path(job), as: :json
      }.to change(ChatSession, :count).by(1)

      expect(response).to have_http_status(:ok)
      chat = ChatSession.last
      expect(chat.user_id).to eq(user.id)
      expect(chat.attached_repositories).to include(repo)
      expect(chat.attached_jobs).to contain_exactly(job)
      expect(job.reload.discussion_chat).to eq(chat)
      expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
    end

    it "reuses the existing discussion chat instead of creating a duplicate" do
      existing_chat = ChatSession.create!(user: user, repository: repo)
      job.chat_attachments.create!(chat_session: existing_chat)

      expect {
        post path(job), as: :json
      }.not_to change(ChatSession, :count)

      expect(parse_body["redirect_to"]).to eq("/chats/#{existing_chat.id}")
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

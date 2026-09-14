require "rails_helper"

RSpec.describe "App API job coding mode", type: :request do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Factories.job_record(user: user, repository: repo, state: "implemented",
                         branch_name: "syrus/fix-login-1")
  end

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def path(job_record) = "/api/v1/app/jobs/#{job_record.id}/open_in_coding_mode"

  context "when coding_mode feature is disabled" do
    before { allow(Feature).to receive(:coding_mode_enabled?).and_return(false) }

    it "returns 422 with feature_disabled error" do
      post path(job), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("feature_disabled")
    end
  end

  context "when coding_mode feature is enabled" do
    before do
      allow(Feature).to receive(:coding_mode_enabled?).and_return(true)
      allow(ChatWorkspace).to receive(:ensure_job_branch_checkout!)
    end

    it "returns 422 for a job in a non-eligible state" do
      running_job = Factories.job_record(user: user, repository: repo, state: "running")

      post path(running_job), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "returns 422 when the job has no branch" do
      no_branch_job = Factories.job_record(user: user, repository: repo, state: "implemented",
                                           branch_name: nil)

      post path(no_branch_job), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "returns 422 when repository GitHub credentials are missing" do
      user.update!(github_token: nil)

      post path(job), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
      expect(parse_body.dig("error", "message")).to eq(JobCodingMode::Takeover::GITHUB_TOKEN_REQUIRED_MESSAGE)
      expect(ChatWorkspace).not_to have_received(:ensure_job_branch_checkout!)
      expect(job.reload).to be_implemented
    end

    it "creates a coding-mode chat session and redirects to it" do
      expect {
        post path(job), as: :json
      }.to change(ChatSession, :count).by(1)

      expect(response).to have_http_status(:ok)
      chat = ChatSession.last
      expect(chat.mode).to eq("coding")
      expect(chat.attached_repositories).to include(repo)
      expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
    end

    it "sets linked_chat_id on the job" do
      post path(job), as: :json

      expect(job.reload.linked_chat_id).to eq(ChatSession.last.id)
      expect(job).to be_coding
    end

    it "initializes the job branch checkout" do
      post path(job), as: :json

      chat = ChatSession.last
      expect(ChatWorkspace).to have_received(:ensure_job_branch_checkout!)
        .with(chat, repo, "syrus/fix-login-1")
    end

    it "uses feedback as the first coding chat prompt" do
      expect {
        post path(job), params: { feedback: "Please tighten the header spacing." }, as: :json
      }.to have_enqueued_job(ChatTurnJob)

      chat = ChatSession.last
      message = chat.messages.where(role: "user").sole
      expect(message.content).to include(
        "text" => "Please tighten the header spacing.",
        "source" => "job_detail_coding_mode_feedback",
        "job_id" => job.id
      )
      expect(chat.chat_queued_messages.sole.delivered_at).to be_present
      expect(parse_body["message"]).to eq("Opened Coding Mode chat and queued your feedback.")
    end

    it "queues feedback on a reused busy coding chat without starting another turn" do
      existing_chat = ChatSession.create!(user: user, mode: "coding", turn_in_flight: true)
      job.update_columns(linked_chat_id: existing_chat.id)

      expect {
        post path(job), params: { feedback: "Start from the feedback form." }, as: :json
      }.not_to have_enqueued_job(ChatTurnJob)

      expect(response).to have_http_status(:ok)
      queued = existing_chat.reload.queued_messages.sole
      expect(queued.content).to include(
        "text" => "Start from the feedback form.",
        "source" => "job_detail_coding_mode_feedback",
        "job_id" => job.id
      )
      expect(existing_chat.messages).to be_empty
      expect(parse_body["redirect_to"]).to eq("/chats/#{existing_chat.id}")
    end

    it "reuses an existing linked chat session" do
      existing_chat = ChatSession.create!(user: user, mode: "coding")
      job.update_columns(linked_chat_id: existing_chat.id)

      expect {
        post path(job), as: :json
      }.not_to change(ChatSession, :count)

      expect(parse_body["redirect_to"]).to eq("/chats/#{existing_chat.id}")
      expect(job.reload).to be_coding
    end

    it "unapproves an approved job before linking" do
      approved_job = Factories.job_record(user: user, repository: repo, state: "approved",
                                          branch_name: "syrus/fix-login-1",
                                          approved_via: "operator",
                                          approved_at: Time.current)
      allow(Job::ApprovalPropagator).to receive(:dismiss).and_return(double(message: nil))

      post path(approved_job), as: :json

      expect(approved_job.reload).to be_coding
    end

    it "does not create a duplicate chat session when called twice for approved job" do
      approved_job = Factories.job_record(user: user, repository: repo, state: "approved",
                                          branch_name: "syrus/fix-login-2",
                                          approved_via: "operator",
                                          approved_at: Time.current)
      allow(Job::ApprovalPropagator).to receive(:dismiss).and_return(double(message: nil))

      post path(approved_job), as: :json
      first_chat_id = approved_job.reload.linked_chat_id

      # Job is now implemented with a linked chat; posting again should reuse it
      expect {
        post path(approved_job), as: :json
      }.not_to change(ChatSession, :count)

      expect(parse_body["redirect_to"]).to eq("/chats/#{first_chat_id}")
    end

    it "rejects a job with active workflow ownership" do
      workflow = Workflow.create!(job: job, trigger_kind: "retry", state: "running")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")
      Run.create!(job: job, user: user, step: step, trigger_kind: "retry", state: "running")

      post path(job), as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("active workflow ownership")
      expect(job.reload).to be_implemented
    end

    it "allows takeover when the only active workflow is a queued initial hold" do
      Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

      post path(job), as: :json

      expect(response).to have_http_status(:ok)
      expect(job.reload).to be_coding
    end

    it "returns 404 for a job owned by another user" do
      other_job = Factories.job_record(user: Factories.user, repository: Factories.repository,
                                       state: "implemented", branch_name: "syrus/other")

      post path(other_job), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end

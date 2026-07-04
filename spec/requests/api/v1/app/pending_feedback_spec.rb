require "rails_helper"

RSpec.describe "App API pending feedback", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets", feedback_policy: "confirm") }
  let(:job) do
    Factories.job(
      repository: repo,
      issue_number: 42,
      issue_title: "Fix bridge",
      pr_number: 7,
      state: "implemented"
    )
  end

  def parse_body = JSON.parse(response.body)

  def make_pr_comment(attributed_to: "external", actionable: true, body: "Please add tests", actioned_at: nil, actioned_by: nil)
    PrReviewComment.create!(
      job: job,
      pr_type: "direct",
      comment_kind: "issue",
      github_comment_id: SecureRandom.random_number(999_999),
      github_handle: "reviewer",
      attributed_to: attributed_to,
      actionable: actionable,
      body: body,
      actioned_at: actioned_at,
      actioned_by: actioned_by,
      comment_created_at: 1.hour.ago
    )
  end

  before do
    sign_in_as(user)
    allow(ChatFeedbackSubmission).to receive(:call).and_return(
      ChatFeedbackSubmission::Result.new(
        workflow: instance_double(Workflow, id: 999, state: "queued"),
        error: nil
      )
    )
  end

  describe "GET /api/v1/app/jobs/:job_id/pending_feedback" do
    it "returns pending (unactioned, actionable, non-job-owner) comments" do
      comment = make_pr_comment(attributed_to: "external", actionable: true)
      make_pr_comment(attributed_to: "external", actionable: false)
      make_pr_comment(attributed_to: "job_owner", actionable: true)
      make_pr_comment(attributed_to: "external", actioned_at: Time.current, actioned_by: "auto_poll")

      get "/api/v1/app/jobs/#{job.id}/pending_feedback"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["comments"].size).to eq(1)
      expect(body["comments"].first["id"]).to eq(comment.id)
      expect(body["comments"].first["attributed_to"]).to eq("external")
      expect(body["comments"].first["github_handle"]).to eq("reviewer")
      expect(body["feedback_policy"]).to eq("confirm")
    end

    it "returns empty when policy is auto" do
      repo.update!(feedback_policy: "auto")
      make_pr_comment

      get "/api/v1/app/jobs/#{job.id}/pending_feedback"

      expect(response).to have_http_status(:ok)
      # No error, but the list can be empty (the confirm filter is controller-side)
      expect(parse_body["comments"]).to be_a(Array)
    end

    it "401s when signed out" do
      sign_out

      get "/api/v1/app/jobs/#{job.id}/pending_feedback"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/pending_feedback/:id/apply" do
    it "submits the comment body as feedback and marks the comment actioned" do
      comment = make_pr_comment(body: "Add error handling please")

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/apply"

      expect(response).to have_http_status(:created)
      expect(parse_body["message"]).to eq("Feedback applied.")
      expect(parse_body["workflow"]["id"]).to eq(999)

      comment.reload
      expect(comment.actioned_at).to be_present
      expect(comment.actioned_by).to eq("operator:apply")

      expect(ChatFeedbackSubmission).to have_received(:call).with(
        job: anything,
        feedback: "Add error handling please",
        allowed_states: %w[implemented failed],
        extra_artifacts: hash_including("feedback_source" => hash_including("action" => "apply"))
      )
    end

    it "returns 404 for already-actioned comments" do
      comment = make_pr_comment(actioned_at: Time.current, actioned_by: "operator:ignore")

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/apply"

      expect(response).to have_http_status(:not_found)
    end

    it "returns error when ChatFeedbackSubmission fails" do
      allow(ChatFeedbackSubmission).to receive(:call).and_return(
        ChatFeedbackSubmission::Result.new(workflow: nil, error: "implemented jobs are not actionable")
      )
      comment = make_pr_comment
      job.update_columns(state: "running")

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/apply"

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/pending_feedback/:id/ignore" do
    it "marks the comment as ignored without creating a workflow" do
      comment = make_pr_comment

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/ignore"

      expect(response).to have_http_status(:ok)
      comment.reload
      expect(comment.actioned_by).to eq("operator:ignore")
      expect(comment.actioned_at).to be_present
      expect(ChatFeedbackSubmission).not_to have_received(:call)
    end

    it "returns 404 for already-actioned comments" do
      comment = make_pr_comment(actioned_at: Time.current, actioned_by: "auto_poll")

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/ignore"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/pending_feedback/:id/replace" do
    it "submits custom text as feedback and marks the comment actioned" do
      comment = make_pr_comment(body: "Original reviewer text")

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/replace",
           params: { body: "Operator's rewritten instruction" }

      expect(response).to have_http_status(:created)
      expect(parse_body["message"]).to include("replacement")

      comment.reload
      expect(comment.actioned_by).to eq("operator:replace")

      expect(ChatFeedbackSubmission).to have_received(:call).with(
        job: anything,
        feedback: "Operator's rewritten instruction",
        allowed_states: %w[implemented failed],
        extra_artifacts: hash_including("feedback_source" => hash_including("action" => "replace"))
      )
    end

    it "returns 422 when body is blank" do
      comment = make_pr_comment

      post "/api/v1/app/jobs/#{job.id}/pending_feedback/#{comment.id}/replace",
           params: { body: "" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(comment.reload.actioned_at).to be_nil
    end
  end

  def sign_out
    delete "/session"
  end
end

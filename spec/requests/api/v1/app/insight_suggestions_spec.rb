require "rails_helper"

RSpec.describe "App API insight suggestions", type: :request do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(user: user, repository: repository, kind: "agent_insight", issue_number: nil) }

  def parse_body
    JSON.parse(response.body)
  end

  def create_suggestion(**attrs)
    InsightSuggestion.create!({
      job:        job,
      repository: repository,
      title:      "Repeated prepare failures",
      category:   "repeated_failure",
      severity:   "high",
      confidence: 0.85
    }.merge(attrs))
  end

  def enable_feature
    Feature.find_or_create_by!(slug: "agent_insights") { |f|
      f.category = "Labs"; f.name = "Agent Insights"
    }.update!(enabled: true)
  end

  def disable_feature
    Feature.find_or_create_by!(slug: "agent_insights") { |f|
      f.category = "Labs"; f.name = "Agent Insights"
    }.update!(enabled: false)
  end

  describe "feature flag off" do
    before { disable_feature }

    it "returns 404 for the list endpoint when unauthenticated" do
      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for the list endpoint when authenticated" do
      sign_in_as(user)
      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("agent_insights_disabled")
    end

    it "returns 404 for the update endpoint" do
      enable_feature
      suggestion = create_suggestion
      disable_feature
      sign_in_as(user)

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}", params: { action_type: "dismiss" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "unauthenticated" do
    before { enable_feature }

    it "returns 401 for the list endpoint" do
      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for the update endpoint" do
      suggestion = create_suggestion
      patch "/api/v1/app/insight_suggestions/#{suggestion.id}", params: { action_type: "dismiss" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/app/repositories/:repository_id/insight_suggestions" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "returns 404 for a repository not belonging to the user" do
      other_repo = Factories.repository(user: Factories.user)

      get "/api/v1/app/repositories/#{other_repo.id}/insight_suggestions"

      expect(response).to have_http_status(:not_found)
    end

    it "returns an empty suggestions list when none exist" do
      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestions"]).to eq([])
      expect(body.dig("repository", "id")).to eq(repository.id)
    end

    it "returns suggestions ordered by severity then confidence" do
      s_low    = create_suggestion(severity: "low",    confidence: 0.9, title: "Low")
      s_medium = create_suggestion(severity: "medium", confidence: 0.5, title: "Medium")
      s_high   = create_suggestion(severity: "high",   confidence: 0.8, title: "High")

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      expect(response).to have_http_status(:ok)
      ids = parse_body["suggestions"].map { |s| s["id"] }
      expect(ids).to eq([ s_high.id, s_medium.id, s_low.id ])
    end

    it "returns the expected fields for each suggestion" do
      create_suggestion(
        title:             "Cache misses",
        category:          "inefficiency",
        severity:          "medium",
        confidence:        0.75,
        suggested_prompt:  "Fix the caching",
        memory_suggestion: "Always warm the cache"
      )

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      suggestion = parse_body["suggestions"].first
      expect(suggestion["title"]).to eq("Cache misses")
      expect(suggestion["category"]).to eq("inefficiency")
      expect(suggestion["severity"]).to eq("medium")
      expect(suggestion["confidence"]).to be_within(0.01).of(0.75)
      expect(suggestion["state"]).to eq("pending")
      expect(suggestion["has_memory_suggestion"]).to be true
      expect(suggestion["suggested_prompt"]).to eq("Fix the caching")
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — dismiss" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "marks the suggestion dismissed" do
      suggestion = create_suggestion

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "dismiss" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["suggestion"]["state"]).to eq("dismissed")
      expect(suggestion.reload.dismissed?).to be true
    end

    it "returns 422 when the suggestion is already accepted" do
      suggestion = create_suggestion
      suggestion.accept!

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "dismiss" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for a suggestion belonging to another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job  = Factories.job(user: other_user, repository: other_repo, kind: "agent_insight", issue_number: nil)
      other_suggestion = InsightSuggestion.create!(
        job: other_job, repository: other_repo,
        title: "Other", category: "c", severity: "low", confidence: 0.5
      )

      patch "/api/v1/app/insight_suggestions/#{other_suggestion.id}",
            params: { action_type: "dismiss" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — accept" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "marks the suggestion accepted without creating a job" do
      suggestion = create_suggestion

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "accept", create_job: false }, as: :json

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestion"]["state"]).to eq("accepted")
      expect(body["job"]).to be_nil
      expect(suggestion.reload.accepted?).to be true
    end

    it "creates a direct job and marks the suggestion accepted when create_job is true" do
      suggestion = create_suggestion(suggested_prompt: "Fix the thing")

      expect {
        patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
              params: { action_type: "accept", create_job: true, prompt: "Fix the thing" }, as: :json
      }.to change(Job, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestion"]["state"]).to eq("accepted")
      expect(body["job"]).not_to be_nil
      expect(body.dig("job", "state")).to be_present
      expect(suggestion.reload.created_job).to be_present
    end

    it "returns 422 when create_job is true but prompt is blank" do
      suggestion = create_suggestion

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "accept", create_job: true, prompt: "" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(suggestion.reload.pending?).to be true
    end

    it "returns 422 when already dismissed" do
      suggestion = create_suggestion
      suggestion.dismiss!

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "accept" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — save_memory" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "creates a repository-scoped ChatMemory from the memory_suggestion" do
      suggestion = create_suggestion(memory_suggestion: "Always check the logs first")

      expect {
        patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
              params: { action_type: "save_memory" }, as: :json
      }.to change(ChatMemory, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to include("saved")

      memory = ChatMemory.last
      expect(memory.kind).to eq("project_fact")
      expect(memory.scope).to eq("repository")
      expect(memory.scope_id).to eq(repository.id)
      expect(memory.source_type).to eq("insight")
      expect(memory.source_id).to eq(suggestion.id)
      expect(memory.content).to eq("Always check the logs first")
    end

    it "returns 422 when the suggestion has no memory_suggestion" do
      suggestion = create_suggestion(memory_suggestion: nil)

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "save_memory" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — unknown action" do
    before { enable_feature; sign_in_as(user) }

    it "returns 422" do
      suggestion = create_suggestion

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "explode" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/app/repositories/:id/run_insight_analysis" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "returns 404 when the feature is disabled" do
      disable_feature

      post "/api/v1/app/repositories/#{repository.id}/run_insight_analysis"

      expect(response).to have_http_status(:not_found)
    end

    it "creates an agent_insight job and workflow" do
      post "/api/v1/app/repositories/#{repository.id}/run_insight_analysis"

      expect(response).to have_http_status(:ok)
      expect(Job.where(kind: "agent_insight", repository: repository).count).to eq(1)
    end

    it "does not create a duplicate when an insight job is already running" do
      existing_job = user.jobs.create!(
        repository: repository,
        kind: "agent_insight",
        issue_number: nil,
        issue_title: "Insight",
        owner_user: user
      )

      expect {
        post "/api/v1/app/repositories/#{repository.id}/run_insight_analysis"
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:ok)
      expect(parse_body).to include("message")
    end
  end
end

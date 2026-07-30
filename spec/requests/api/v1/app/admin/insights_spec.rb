require "rails_helper"

RSpec.describe "Admin API insight suggestions", type: :request do
  let(:admin)      { Factories.user(admin: true) }
  let(:other_user) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: other_user) }
  let(:job)        { Factories.job(user: other_user, repository: repository, kind: "agent_insight", issue_number: nil) }

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

    it "returns 404 for the index endpoint when admin" do
      sign_in_as(admin)
      get "/api/v1/app/admin/insights"
      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("agent_insights_disabled")
    end

    it "returns 404 for promote_memory when admin" do
      sign_in_as(admin)
      post "/api/v1/app/admin/insights/999/promote_memory"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "unauthenticated" do
    before { enable_feature }

    it "returns 401 for the index endpoint" do
      get "/api/v1/app/admin/insights"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for promote_memory" do
      post "/api/v1/app/admin/insights/999/promote_memory"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "non-admin user" do
    before do
      admin  # ensure admin is the first user created
      enable_feature
      sign_in_as(other_user)
    end

    it "returns 403 for the index endpoint" do
      get "/api/v1/app/admin/insights"
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 403 for promote_memory" do
      suggestion = create_suggestion(memory_suggestion: "Always check logs first")
      post "/api/v1/app/admin/insights/#{suggestion.id}/promote_memory"
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/v1/app/admin/insights" do
    before do
      enable_feature
      sign_in_as(admin)
    end

    it "returns an empty list when no suggestions exist" do
      get "/api/v1/app/admin/insights"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestions"]).to eq([])
      expect(body["meta"]).to include("total" => 0, "page" => 1, "per_page" => 20, "total_pages" => 1)
    end

    it "returns meta with total, page, per_page, and total_pages" do
      3.times { create_suggestion }

      get "/api/v1/app/admin/insights"

      body = parse_body
      expect(body["meta"]).to include(
        "total"       => 3,
        "page"        => 1,
        "per_page"    => 20,
        "total_pages" => 1
      )
    end

    it "paginates suggestions and returns the correct subset on page 2" do
      25.times { |i| create_suggestion(title: "Suggestion #{i}", confidence: (25 - i).to_f / 25) }

      get "/api/v1/app/admin/insights", params: { page: 2, per_page: 20 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestions"].length).to eq(5)
      expect(body["meta"]).to include(
        "total"       => 25,
        "page"        => 2,
        "per_page"    => 20,
        "total_pages" => 2
      )
    end

    it "returns suggestions across all repositories ordered by severity then confidence" do
      other_repo2 = Factories.repository(user: other_user)
      job2 = Factories.job(user: other_user, repository: other_repo2, kind: "agent_insight", issue_number: nil)

      s_low    = create_suggestion(severity: "low",    confidence: 0.9, title: "Low")
      s_medium = InsightSuggestion.create!(
        job: job2, repository: other_repo2,
        title: "Medium", category: "c", severity: "medium", confidence: 0.5
      )
      s_high   = create_suggestion(severity: "high",   confidence: 0.8, title: "High")

      get "/api/v1/app/admin/insights"

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

      get "/api/v1/app/admin/insights"

      suggestion = parse_body["suggestions"].first
      expect(suggestion["title"]).to eq("Cache misses")
      expect(suggestion["category"]).to eq("inefficiency")
      expect(suggestion["severity"]).to eq("medium")
      expect(suggestion["confidence"]).to be_within(0.01).of(0.75)
      expect(suggestion["state"]).to eq("pending")
      expect(suggestion["has_memory_suggestion"]).to be true
      expect(suggestion["suggested_prompt"]).to eq("Fix the caching")
      expect(suggestion["repository"]["id"]).to eq(repository.id)
      expect(suggestion["repository"]["slug"]).to eq(repository.slug)
      expect(suggestion["user"]["id"]).to eq(other_user.id)
    end
  end

  describe "POST /api/v1/app/admin/insights/:id/promote_memory" do
    before do
      enable_feature
      sign_in_as(admin)
    end

    it "creates an instance-scoped ChatMemory from the memory_suggestion" do
      suggestion = create_suggestion(memory_suggestion: "Always check the logs first")

      expect {
        post "/api/v1/app/admin/insights/#{suggestion.id}/promote_memory"
      }.to change(ChatMemory, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to include("promoted")

      memory = ChatMemory.last
      expect(memory.kind).to eq("project_fact")
      expect(memory.scope).to eq("instance")
      expect(memory.scope_id).to be_nil
      expect(memory.source_type).to eq("insight")
      expect(memory.source_id).to eq(suggestion.id)
      expect(memory.author).to eq("admin")
      expect(memory.content).to eq("Always check the logs first")
    end

    it "returns 404 when the suggestion does not exist" do
      post "/api/v1/app/admin/insights/999999/promote_memory"
      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 when the suggestion has no memory_suggestion" do
      suggestion = create_suggestion(memory_suggestion: nil)

      post "/api/v1/app/admin/insights/#{suggestion.id}/promote_memory"

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end

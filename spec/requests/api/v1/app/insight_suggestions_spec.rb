require "rails_helper"

RSpec.describe "App API insight suggestions", type: :request do
  let!(:seed_admin) { Factories.user(admin: true) }
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
      expect(body["meta"]).to include("total" => 0, "page" => 1, "per_page" => 20, "total_pages" => 1)
    end

    it "returns tabs including the insights tab" do
      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      expect(response).to have_http_status(:ok)
      tab_keys = parse_body["tabs"].map { |t| t["key"] }
      expect(tab_keys).to include("overview", "github_issues", "documents", "scheduled_tasks", "insights")
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

    it "returns meta with total, page, per_page, and total_pages" do
      3.times { create_suggestion }

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      body = parse_body
      expect(body["meta"]).to include(
        "total"       => 3,
        "page"        => 1,
        "per_page"    => 20,
        "total_pages" => 1
      )
    end

    it "filters suggestions by state and returns unfiltered state counts" do
      create_suggestion(title: "Pending")
      accepted = create_suggestion(title: "Accepted")
      dismissed = create_suggestion(title: "Dismissed")
      accepted.accept!
      dismissed.dismiss!

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions", params: { state: "accepted" }

      body = parse_body
      expect(body["suggestions"].map { |s| s["id"] }).to eq([ accepted.id ])
      expect(body["meta"]).to include("total" => 1, "state" => "accepted")
      expect(body.dig("meta", "counts")).to include(
        "pending"   => 1,
        "accepted"  => 1,
        "dismissed" => 1,
        "all"       => 3
      )
    end

    it "auto-accepts stale remove_memory suggestions whose target memory was already deleted" do
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "Old memory."
      )
      suggestion = create_suggestion(
        proposal_type: "remove_memory",
        target_memory: memory,
        stale_memory_text: memory.content,
        stale_memory_evidence: "The memory is obsolete."
      )
      memory.soft_delete_by!(user)

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions", params: { state: "pending" }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestions"].map { |s| s["id"] }).not_to include(suggestion.id)
      expect(body.dig("meta", "counts")).to include(
        "pending"  => 0,
        "accepted" => 1,
        "all"      => 1
      )
      expect(suggestion.reload.accepted?).to be true
    end

    it "paginates suggestions and returns the correct subset on page 2" do
      suggestions = 25.times.map { |i| create_suggestion(title: "Suggestion #{i}", confidence: (25 - i).to_f / 25) }

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions", params: { page: 2, per_page: 20 }

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

    it "paginates within the requested state and returns counts for every tab" do
      3.times { |i| create_suggestion(title: "Pending #{i}") }
      2.times do |i|
        suggestion = create_suggestion(title: "Dismissed #{i}")
        suggestion.dismiss!
      end
      25.times do |i|
        suggestion = create_suggestion(title: "Accepted #{i}", confidence: (25 - i).to_f / 25)
        suggestion.accept!
      end

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions",
          params: { state: "accepted", page: 2, per_page: 20 }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["suggestions"].length).to eq(5)
      expect(body["suggestions"].pluck("state").uniq).to eq([ "accepted" ])
      expect(body["counts"]).to include(
        "pending"   => 3,
        "accepted"  => 25,
        "dismissed" => 2,
        "all"       => 30
      )
      expect(body["meta"]).to include(
        "total"       => 25,
        "page"        => 2,
        "per_page"    => 20,
        "total_pages" => 2
      )
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
      expect(suggestion["proposal_type"]).to eq("create_job")
      expect(suggestion["has_memory_suggestion"]).to be true
      expect(suggestion["suggested_prompt"]).to eq("Fix the caching")
    end

    it "redacts GitHub credentials from suggestion copy before rendering" do
      create_suggestion(
        title: "Leak https://x-access-token:ghs_titlesecret@github.com/acme/widgets.git",
        category: "leak https://x-access-token:ghs_categorysecret@github.com/acme/widgets.git",
        suggested_prompt: "Fix git clone https://x-access-token:ghs_promptsecret@github.com/acme/widgets.git",
        memory_suggestion: "Avoid git ls-remote https://x-access-token:github_pat_memorysecret@github.com/acme/widgets.git"
      )

      get "/api/v1/app/repositories/#{repository.id}/insight_suggestions"

      text = response.body
      expect(text).to include("https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
      expect(text).not_to include("ghs_titlesecret")
      expect(text).not_to include("ghs_categorysecret")
      expect(text).not_to include("ghs_promptsecret")
      expect(text).not_to include("github_pat_memorysecret")
      expect(text).not_to include("x-access-token:ghs_")
      expect(text).not_to include("x-access-token:github_pat_")
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

    it "soft-deletes the target memory when accepting a remove_memory suggestion" do
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "Old bug still exists."
      )
      suggestion = create_suggestion(
        proposal_type: "remove_memory",
        target_memory: memory,
        stale_memory_text: memory.content,
        stale_memory_evidence: "Current specs cover the fixed path."
      )

      expect {
        patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
              params: { action_type: "accept" }, as: :json
      }.to change(ChatMemoryAuditEvent.where(chat_memory: memory, event_type: "deleted"), :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to include("Memory removed")
      expect(parse_body["suggestion"]["state"]).to eq("accepted")
      expect(parse_body["memory_id"]).to eq(memory.id)
      expect(memory.reload.deleted_at).to be_present
      expect(memory.deleted_by_user).to eq(user)
    end

    it "accepts a remove_memory suggestion when the target memory was already deleted" do
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "Already gone."
      )
      suggestion = create_suggestion(
        proposal_type: "remove_memory",
        target_memory: memory,
        stale_memory_text: memory.content,
        stale_memory_evidence: "Current code disagrees with this memory."
      )
      memory.soft_delete_by!(user)

      expect {
        patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
              params: { action_type: "accept" }, as: :json
      }.not_to change(ChatMemoryAuditEvent.where(chat_memory: memory, event_type: "deleted"), :count)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to include("already removed")
      expect(parse_body["suggestion"]["state"]).to eq("accepted")
      expect(parse_body["memory_id"]).to eq(memory.id)
      expect(suggestion.reload.accepted?).to be true
    end

    it "rejects remove_memory acceptance for a memory the user cannot delete" do
      other_user = Factories.user
      memory = ChatMemory.create!(
        user: other_user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "Published stale memory.",
        published: true
      )
      suggestion = create_suggestion(
        proposal_type: "remove_memory",
        target_memory: memory,
        stale_memory_evidence: "Wrong."
      )

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "accept" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(memory.reload.deleted_at).to be_nil
      expect(suggestion.reload.pending?).to be true
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

    it "redacts GitHub credentials before saving a memory from a suggestion" do
      suggestion = create_suggestion(
        memory_suggestion: "Avoid copying https://x-access-token:ghs_memorysecret@github.com/acme/widgets.git"
      )

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "save_memory" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(ChatMemory.last.content).to eq(
        "Avoid copying https://x-access-token:[REDACTED]@github.com/acme/widgets.git"
      )
    end

    it "returns 422 when the suggestion has no memory_suggestion" do
      suggestion = create_suggestion(memory_suggestion: nil)

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "save_memory" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — undismiss" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "transitions a dismissed suggestion back to pending" do
      suggestion = create_suggestion
      suggestion.dismiss!

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "undismiss" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["suggestion"]["state"]).to eq("pending")
      expect(parse_body["message"]).to include("pending")
      expect(suggestion.reload.pending?).to be true
      expect(suggestion.reload.dismissed_at).to be_nil
    end

    it "returns 422 when the suggestion is not dismissed (pending)" do
      suggestion = create_suggestion

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "undismiss" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(suggestion.reload.pending?).to be true
    end

    it "returns 422 when the suggestion is accepted" do
      suggestion = create_suggestion
      suggestion.accept!

      patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
            params: { action_type: "undismiss" }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(suggestion.reload.accepted?).to be true
    end

    it "returns 404 for a suggestion belonging to another user" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job  = Factories.job(user: other_user, repository: other_repo, kind: "agent_insight", issue_number: nil)
      other_suggestion = InsightSuggestion.create!(
        job: other_job, repository: other_repo,
        title: "Other", category: "c", severity: "low", confidence: 0.5
      )
      other_suggestion.dismiss!

      patch "/api/v1/app/insight_suggestions/#{other_suggestion.id}",
            params: { action_type: "undismiss" }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/app/insight_suggestions/:id — save_memory on accepted suggestion" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "can save memory on an accepted suggestion (independent of job acceptance)" do
      suggestion = create_suggestion(memory_suggestion: "Always warm the cache")
      suggestion.accept!

      expect {
        patch "/api/v1/app/insight_suggestions/#{suggestion.id}",
              params: { action_type: "save_memory" }, as: :json
      }.to change(ChatMemory, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body["message"]).to include("saved")
      expect(suggestion.reload.accepted?).to be true
    end
  end

  describe "POST /api/v1/app/insight_suggestions/:id/discuss" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "creates a repository-scoped chat seeded with the insight context" do
      suggestion = create_suggestion(
        title: "Prepare failures need triage",
        category: "repeated_failure",
        severity: "high",
        confidence: 0.91,
        proposal_type: "create_job",
        suggested_prompt: "Fix repeated bundle install failures.",
        evidence: [
          { "kind" => "failure", "job_id" => job.id, "run_id" => 73616 }
        ]
      )

      expect {
        post "/api/v1/app/insight_suggestions/#{suggestion.id}/discuss", as: :json
      }.to change(ChatSession, :count).by(1)
        .and change(ChatMessage.where(role: "user"), :count).by(1)

      expect(response).to have_http_status(:created)
      chat = ChatSession.order(:id).last
      message_text = chat.messages.order(:id).last.content["text"]
      expect(parse_body["redirect_to"]).to eq("/chats/#{chat.id}")
      expect(chat.repository).to eq(repository)
      expect(message_text).to include("Title: Prepare failures need triage")
      expect(message_text).to include("Severity: high")
      expect(message_text).to include("Category: repeated_failure")
      expect(message_text).to include("Confidence: 0.91")
      expect(message_text).to include("Proposal type: create_job")
      expect(message_text).to include("Fix repeated bundle install failures.")
      expect(message_text).to include("/jobs/#{job.id}")
      expect(message_text).to include("/admin/runs/73616/transcript")
    end

    it "returns 404 for a suggestion belonging to another user's repository" do
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_job = Factories.job(user: other_user, repository: other_repo, kind: "agent_insight", issue_number: nil)
      other_suggestion = InsightSuggestion.create!(
        job: other_job,
        repository: other_repo,
        title: "Other",
        category: "c",
        severity: "low",
        confidence: 0.5
      )

      post "/api/v1/app/insight_suggestions/#{other_suggestion.id}/discuss", as: :json

      expect(response).to have_http_status(:not_found)
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

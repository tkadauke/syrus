require "rails_helper"

RSpec.describe "App API insight schedule configs", type: :request do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def parse_body
    JSON.parse(response.body)
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
    before { disable_feature; sign_in_as(user) }

    it "returns 403 for GET when feature is disabled" do
      get "/api/v1/app/repositories/#{repository.id}/insight_schedule_config"

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("agent_insights_disabled")
    end

    it "returns 403 for PATCH when feature is disabled" do
      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("agent_insights_disabled")
    end
  end

  describe "unauthenticated" do
    before { enable_feature }

    it "returns 401 for GET" do
      get "/api/v1/app/repositories/#{repository.id}/insight_schedule_config"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for PATCH" do
      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/app/repositories/:id/insight_schedule_config" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "returns default config when no InsightScheduleConfig record exists" do
      get "/api/v1/app/repositories/#{repository.id}/insight_schedule_config"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["enabled"]).to be false
      expect(body["min_jobs_since_last_run"]).to eq(5)
      expect(body["max_jobs_since_last_run"]).to eq(10)
    end

    it "returns the existing config when one exists" do
      InsightScheduleConfig.create!(
        repository: repository,
        enabled: true,
        min_jobs_since_last_run: 3,
        max_jobs_since_last_run: 8
      )

      get "/api/v1/app/repositories/#{repository.id}/insight_schedule_config"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["enabled"]).to be true
      expect(body["min_jobs_since_last_run"]).to eq(3)
      expect(body["max_jobs_since_last_run"]).to eq(8)
    end

    it "returns 404 for a repository not belonging to the user" do
      other_repo = Factories.repository(user: Factories.user)

      get "/api/v1/app/repositories/#{other_repo.id}/insight_schedule_config"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/app/repositories/:id/insight_schedule_config" do
    before do
      enable_feature
      sign_in_as(user)
    end

    it "creates a new config when none exists" do
      expect {
        patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
              params: { enabled: true, min_jobs_since_last_run: 4, max_jobs_since_last_run: 9 }, as: :json
      }.to change(InsightScheduleConfig, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["message"]).to be_present
      expect(body.dig("config", "enabled")).to be true
      expect(body.dig("config", "min_jobs_since_last_run")).to eq(4)
      expect(body.dig("config", "max_jobs_since_last_run")).to eq(9)
    end

    it "updates an existing config" do
      config = InsightScheduleConfig.create!(
        repository: repository,
        enabled: false,
        min_jobs_since_last_run: 5,
        max_jobs_since_last_run: 10
      )

      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true, min_jobs_since_last_run: 2, max_jobs_since_last_run: 6 }, as: :json

      expect(response).to have_http_status(:ok)
      config.reload
      expect(config.enabled).to be true
      expect(config.min_jobs_since_last_run).to eq(2)
      expect(config.max_jobs_since_last_run).to eq(6)
    end

    it "returns 422 when min >= max" do
      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true, min_jobs_since_last_run: 10, max_jobs_since_last_run: 5 }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "returns 422 when min equals max" do
      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true, min_jobs_since_last_run: 5, max_jobs_since_last_run: 5 }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when min is less than 1" do
      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: true, min_jobs_since_last_run: 0, max_jobs_since_last_run: 5 }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for a repository not belonging to the user" do
      other_repo = Factories.repository(user: Factories.user)

      patch "/api/v1/app/repositories/#{other_repo.id}/insight_schedule_config",
            params: { enabled: true }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "can disable an enabled config" do
      InsightScheduleConfig.create!(
        repository: repository,
        enabled: true,
        min_jobs_since_last_run: 5,
        max_jobs_since_last_run: 10
      )

      patch "/api/v1/app/repositories/#{repository.id}/insight_schedule_config",
            params: { enabled: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(repository.insight_schedule_config.reload.enabled).to be false
    end
  end
end

require "rails_helper"

RSpec.describe "App API build cache repository settings", type: :request do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def parse_body
    JSON.parse(response.body)
  end

  describe "unauthenticated" do
    it "returns 401 for GET" do
      get "/api/v1/app/repositories/#{repository.id}/build_cache_settings"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 for PATCH" do
      patch "/api/v1/app/repositories/#{repository.id}/build_cache_settings",
            params: { basedirs_safe: true }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/app/repositories/:id/build_cache_settings" do
    before { sign_in_as(user) }

    it "defaults to false when no settings row exists" do
      get "/api/v1/app/repositories/#{repository.id}/build_cache_settings"

      expect(response).to have_http_status(:ok)
      expect(parse_body["basedirs_safe"]).to be false
    end

    it "returns the existing opt-in" do
      BuildCache::RepositorySettings.create!(repository: repository, basedirs_safe: true)

      get "/api/v1/app/repositories/#{repository.id}/build_cache_settings"

      expect(response).to have_http_status(:ok)
      expect(parse_body["basedirs_safe"]).to be true
    end

    it "returns 404 for a repository not belonging to the user" do
      other_repo = Factories.repository(user: Factories.user)

      get "/api/v1/app/repositories/#{other_repo.id}/build_cache_settings"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/app/repositories/:id/build_cache_settings" do
    before { sign_in_as(user) }

    it "creates a settings row when none exists" do
      expect {
        patch "/api/v1/app/repositories/#{repository.id}/build_cache_settings",
              params: { basedirs_safe: true }, as: :json
      }.to change(BuildCache::RepositorySettings, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(parse_body["basedirs_safe"]).to be true
      expect(BuildCache::RepositorySettings.basedirs_safe_for?(repository)).to be true
    end

    it "updates an existing settings row" do
      settings = BuildCache::RepositorySettings.create!(repository: repository, basedirs_safe: true)

      patch "/api/v1/app/repositories/#{repository.id}/build_cache_settings",
            params: { basedirs_safe: false }, as: :json

      expect(response).to have_http_status(:ok)
      expect(settings.reload.basedirs_safe?).to be false
    end

    it "returns 404 for a repository not belonging to the user" do
      other_repo = Factories.repository(user: Factories.user)

      patch "/api/v1/app/repositories/#{other_repo.id}/build_cache_settings",
            params: { basedirs_safe: true }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end

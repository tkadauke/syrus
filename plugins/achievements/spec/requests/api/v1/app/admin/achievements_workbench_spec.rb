require "rails_helper"

RSpec.describe "Achievements workbench", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }

  def set_enabled(name, value)
    PluginRecord.find_or_create_by!(name: name).update!(enabled: value, disableable: true)
  end

  before do
    set_enabled("achievements", true)
    set_enabled("syrus_dev", true)
  end

  describe "GET /api/v1/app/admin/achievements/workbench" do
    it "returns the catalog to an admin" do
      sign_in_as(admin)
      get "/api/v1/app/admin/achievements/workbench"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["definitions"].map { |row| row["key"] }).to include("example.first_job_landed")
    end

    it "rejects a non-admin" do
      sign_in_as(user)
      get "/api/v1/app/admin/achievements/workbench"

      expect(response).to have_http_status(:forbidden)
    end

    it "is unavailable while syrus_dev is disabled" do
      set_enabled("syrus_dev", false)
      sign_in_as(admin)
      get "/api/v1/app/admin/achievements/workbench"

      expect(response).to have_http_status(:not_found)
    end

    it "is not served while achievements is disabled" do
      set_enabled("achievements", false)
      sign_in_as(admin)
      get "/api/v1/app/admin/achievements/workbench"

      expect(response).to have_http_status(:not_found)
    end
  end

  # The SPA resolves /admin/achievements_workbench only from the pages the
  # server contributes, so the page route is unavailable exactly when the
  # contribution is absent.
  describe "GET /api/v1/app/admin/plugin_pages" do
    def workbench_pages = JSON.parse(response.body)["pages"].select { |page| page["id"] == "achievements.workbench" }

    it "lists the workbench for an admin when both plugins are enabled" do
      sign_in_as(admin)
      get "/api/v1/app/admin/plugin_pages"

      expect(workbench_pages.map { |page| page["path"] }).to eq([ "/admin/achievements_workbench" ])
    end

    it "drops the entry when syrus_dev is disabled" do
      set_enabled("syrus_dev", false)
      sign_in_as(admin)
      get "/api/v1/app/admin/plugin_pages"

      expect(workbench_pages).to be_empty
    end
  end
end

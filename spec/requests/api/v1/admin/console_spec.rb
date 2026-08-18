require "rails_helper"

RSpec.describe "API: /api/v1/admin/console", type: :request do
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }
  let(:non_admin) { Factories.user }
  let(:non_admin_token) { non_admin.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
  end

  describe "GET /api/v1/admin/console" do
    it "returns current pause settings and recent actions" do
      AppSetting.current.update!(polling_paused: true, runs_paused: false)
      AdminAction.log!(user: admin, action: :pause_polling, params: { source: "test" })
      Factories.job

      get "/api/v1/admin/console", headers: auth

      expect(response).to be_successful
      expect(parse_body["settings"]).to include(
        "polling_paused" => true,
        "runs_paused" => false
      )
      expect(parse_body["recent_admin_actions"].first).to include(
        "action" => "pause_polling",
        "user_email" => admin.email_address
      )
      expect(parse_body["active_runs"]).to eq(1)
    end

    it "401s without a token" do
      get "/api/v1/admin/console"
      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for non-admin users" do
      get "/api/v1/admin/console", headers: auth(non_admin_token)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "pause toggles" do
    it "pauses and resumes polling" do
      expect {
        post "/api/v1/admin/console/pause_polling", headers: auth
      }.to change { AppSetting.current.tap(&:reload).polling_paused }.from(false).to(true)
        .and change { AdminAction.where(action: "pause_polling").count }.by(1)

      expect(response).to be_successful
      expect(parse_body.dig("settings", "polling_paused")).to be true

      expect {
        post "/api/v1/admin/console/unpause_polling", headers: auth
      }.to change { AppSetting.current.tap(&:reload).polling_paused }.from(true).to(false)
        .and change { AdminAction.where(action: "unpause_polling").count }.by(1)
    end

    it "pauses and resumes runs" do
      expect {
        post "/api/v1/admin/console/pause_runs", headers: auth
      }.to change { AppSetting.current.tap(&:reload).runs_paused }.from(false).to(true)
        .and change { AdminAction.where(action: "pause_runs").count }.by(1)

      expect(parse_body.dig("settings", "runs_paused")).to be true

      expect {
        post "/api/v1/admin/console/unpause_runs", headers: auth
      }.to change { AppSetting.current.tap(&:reload).runs_paused }.from(true).to(false)
        .and change { AdminAction.where(action: "unpause_runs").count }.by(1)
    end
  end
end

require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/console", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/console"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/console"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns current settings, cache-scope users, and recent actions" do
    sign_in_as(admin)
    AppSetting.current.update!(polling_paused: true, runs_paused: false)
    AdminAction.log!(user: admin, action: :pause_polling, params: { source: "test" })

    get "/api/v1/app/admin/console"

    expect(response).to have_http_status(:ok)
    expect(parse_body["settings"]).to include(
      "polling_paused" => true,
      "runs_paused" => false
    )
    expect(parse_body["users"].first).to include(
      "id" => admin.id,
      "email_address" => admin.email_address
    )
    expect(parse_body["recent_admin_actions"].first).to include(
      "action" => "pause_polling",
      "user_email" => admin.email_address
    )
    expect(parse_body["active_runs"]).to eq(0)
  end

  it "pauses and resumes polling and runs" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/console/pause_polling"
    }.to change { AppSetting.current.tap(&:reload).polling_paused }.from(false).to(true)
      .and change { AdminAction.where(action: "pause_polling").count }.by(1)
    expect(parse_body.dig("settings", "polling_paused")).to be true

    expect {
      post "/api/v1/app/admin/console/unpause_polling"
    }.to change { AppSetting.current.tap(&:reload).polling_paused }.from(true).to(false)
      .and change { AdminAction.where(action: "unpause_polling").count }.by(1)

    expect {
      post "/api/v1/app/admin/console/pause_runs"
    }.to change { AppSetting.current.tap(&:reload).runs_paused }.from(false).to(true)
      .and change { AdminAction.where(action: "pause_runs").count }.by(1)
    expect(parse_body.dig("settings", "runs_paused")).to be true

    expect {
      post "/api/v1/app/admin/console/unpause_runs"
    }.to change { AppSetting.current.tap(&:reload).runs_paused }.from(true).to(false)
      .and change { AdminAction.where(action: "unpause_runs").count }.by(1)
  end

  it "enables and disables the Epic merge-train" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/console/enable_merge_train"
    }.to change { AppSetting.current.tap(&:reload).merge_train_enabled }.from(false).to(true)
      .and change { AdminAction.where(action: "enable_merge_train").count }.by(1)
    expect(parse_body.dig("settings", "merge_train_enabled")).to be true

    expect {
      post "/api/v1/app/admin/console/disable_merge_train"
    }.to change { AppSetting.current.tap(&:reload).merge_train_enabled }.from(true).to(false)
      .and change { AdminAction.where(action: "disable_merge_train").count }.by(1)
    expect(parse_body.dig("settings", "merge_train_enabled")).to be false
  end

  it "clears GitHub cache entries" do
    sign_in_as(admin)
    target = Factories.user(email_address: "target@example.com")
    expect(Rails.cache).to receive(:delete_matched).with("github_etag/u#{target.id}/*").and_return(2)

    post "/api/v1/app/admin/console/clear_github_cache", params: { user_id: target.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Cleared 2 GitHub cache entries for target@example.com.")
    expect(AdminAction.where(action: "clear_github_cache").count).to eq(1)
  end
end

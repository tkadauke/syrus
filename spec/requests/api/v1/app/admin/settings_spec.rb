require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/settings", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns editable settings and an empty clearable secrets list" do
    sign_in_as(admin)
    AppSetting.current.update!(signups_open: true)

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("settings", "signups_open")).to be true
    expect(body.dig("settings", "clearable_secrets")).to eq([])
  end

  it "updates signups_open" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: {
        signups_open: true
      }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.signups_open).to be true
    expect(parse_body["message"]).to eq("Settings updated.")
  end

  it "exposes and updates the walkthrough-video storage settings" do
    sign_in_as(admin)

    get "/api/v1/app/admin/settings"
    expect(parse_body.dig("settings", "video_retention_days")).to eq(7)
    expect(parse_body.dig("settings", "video_storage_budget_mb")).to eq(2048)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: false, video_retention_days: 14, video_storage_budget_mb: 512 }
    }

    expect(response).to have_http_status(:ok)
    setting = AppSetting.current.reload
    expect(setting.video_retention_days).to eq(14)
    expect(setting.video_storage_budget_mb).to eq(512)
    # signups_open (a boolean false) must still be applied, not blank-rejected.
    expect(setting.signups_open).to be false
  end

  it "exposes and updates the global agent-concurrency cap" do
    sign_in_as(admin)

    get "/api/v1/app/admin/settings"
    expect(parse_body.dig("settings", "max_concurrent_agent_runs")).to eq(0)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: true, max_concurrent_agent_runs: 4 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.max_concurrent_agent_runs).to eq(4)
  end

  it "rejects a destructive video_retention_days of 0 without persisting it" do
    sign_in_as(admin)
    AppSetting.current.update!(video_retention_days: 7)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { video_retention_days: 0 }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    # The prior safe value is preserved — 0 would purge every stored video.
    expect(AppSetting.current.reload.video_retention_days).to eq(7)
  end

  it "exposes and updates the proactive rebase commit threshold" do
    sign_in_as(admin)

    get "/api/v1/app/admin/settings"
    expect(parse_body.dig("settings", "proactive_rebase_commit_threshold")).to eq(20)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: false, proactive_rebase_commit_threshold: 50 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.proactive_rebase_commit_threshold).to eq(50)
  end

  it "exposes and updates the rebase failure cooldown" do
    sign_in_as(admin)

    get "/api/v1/app/admin/settings"
    expect(parse_body.dig("settings", "rebase_failure_cooldown_minutes")).to eq(60)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: false, rebase_failure_cooldown_minutes: 15 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.rebase_failure_cooldown_minutes).to eq(15)
  end

  it "rejects a proactive_rebase_commit_threshold below 1" do
    sign_in_as(admin)
    AppSetting.current.update!(proactive_rebase_commit_threshold: 20)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: false, proactive_rebase_commit_threshold: 0 }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(AppSetting.current.reload.proactive_rebase_commit_threshold).to eq(20)
  end

  it "rejects a negative rebase_failure_cooldown_minutes" do
    sign_in_as(admin)
    AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: { signups_open: false, rebase_failure_cooldown_minutes: -1 }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(AppSetting.current.reload.rebase_failure_cooldown_minutes).to eq(60)
  end

  it "rejects unknown app secret names" do
    sign_in_as(admin)

    post "/api/v1/app/admin/settings/clear_secret", params: { secret: "github_app_id" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unknown_secret")
  end
end

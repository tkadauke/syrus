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

  it "returns editable settings and secret presence without secret values" do
    sign_in_as(admin)
    AppSetting.current.update!(
      signups_open: true,
      telegram_bot_token: "bot-token",
      telegram_webhook_secret: nil
    )

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("settings", "signups_open")).to be true
    expect(body.dig("settings", "clearable_secrets")).to contain_exactly(
      { "key" => "telegram_bot_token", "label" => "Telegram bot token", "set" => true },
      { "key" => "telegram_webhook_secret", "label" => "Telegram webhook secret", "set" => false }
    )
    expect(response.body).not_to include("bot-token")
  end

  it "loads when an optional app secret column has not been migrated yet" do
    sign_in_as(admin)

    AppSetting.connection.remove_column(:app_settings, :telegram_webhook_secret) if AppSetting.column_names.include?("telegram_webhook_secret")
    AppSetting.reset_column_information

    get "/api/v1/app/admin/settings"

    expect(response).to have_http_status(:ok)
    secrets = parse_body.dig("settings", "clearable_secrets")
    expect(secrets).to contain_exactly(
      { "key" => "telegram_bot_token", "label" => "Telegram bot token", "set" => false }
    )
  ensure
    unless AppSetting.connection.column_exists?(:app_settings, :telegram_webhook_secret)
      AppSetting.connection.add_column(:app_settings, :telegram_webhook_secret, :text)
    end
    AppSetting.reset_column_information
  end

  it "updates available settings when optional secret columns have not been migrated yet" do
    sign_in_as(admin)

    AppSetting.connection.remove_column(:app_settings, :telegram_webhook_secret) if AppSetting.column_names.include?("telegram_webhook_secret")
    AppSetting.reset_column_information

    patch "/api/v1/app/admin/settings", params: {
      app_setting: {
        signups_open: true,
        telegram_webhook_secret: "webhook-secret"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.signups_open).to be true
    expect(parse_body["message"]).to eq("Settings updated.")
  ensure
    unless AppSetting.connection.column_exists?(:app_settings, :telegram_webhook_secret)
      AppSetting.connection.add_column(:app_settings, :telegram_webhook_secret, :text)
    end
    AppSetting.reset_column_information
  end

  it "updates signups and provided Telegram secrets" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/settings", params: {
      app_setting: {
        signups_open: true,
        telegram_bot_token: "bot-token",
        telegram_webhook_secret: "webhook-secret"
      }
    }

    setting = AppSetting.current.reload
    expect(response).to have_http_status(:ok)
    expect(setting.signups_open).to be true
    expect(setting.telegram_bot_token).to eq("bot-token")
    expect(setting.telegram_webhook_secret).to eq("webhook-secret")
    expect(parse_body["message"]).to eq("Settings updated.")
  end

  it "keeps Telegram secrets unchanged when update fields are blank" do
    sign_in_as(admin)
    setting = AppSetting.current
    setting.update!(telegram_bot_token: "bot-token", telegram_webhook_secret: "webhook-secret")

    patch "/api/v1/app/admin/settings", params: {
      app_setting: {
        signups_open: false,
        telegram_bot_token: "",
        telegram_webhook_secret: ""
      }
    }

    setting.reload
    expect(setting.signups_open).to be false
    expect(setting.telegram_bot_token).to eq("bot-token")
    expect(setting.telegram_webhook_secret).to eq("webhook-secret")
  end

  it "clears known app-wide secrets" do
    sign_in_as(admin)
    setting = AppSetting.current
    setting.update!(telegram_bot_token: "bot-token")

    post "/api/v1/app/admin/settings/clear_secret", params: { secret: "telegram_bot_token" }

    expect(response).to have_http_status(:ok)
    expect(setting.reload.telegram_bot_token).to be_nil
    expect(parse_body["message"]).to eq("Telegram bot token cleared.")
    secret = parse_body.dig("settings", "clearable_secrets").find { |row| row["key"] == "telegram_bot_token" }
    expect(secret["set"]).to be false
  end

  it "rejects unknown app secret names" do
    sign_in_as(admin)

    post "/api/v1/app/admin/settings/clear_secret", params: { secret: "github_app_id" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unknown_secret")
  end
end

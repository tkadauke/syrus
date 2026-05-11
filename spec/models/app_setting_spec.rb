require "rails_helper"

RSpec.describe AppSetting do
  it ".current creates the singleton row on first call" do
    expect { AppSetting.current }.to change(AppSetting, :count).from(0).to(1)
  end

  it ".current returns the existing row on subsequent calls" do
    AppSetting.create!
    expect { AppSetting.current }.not_to change(AppSetting, :count)
  end

  it ".signups_open? defaults to false" do
    expect(AppSetting.signups_open?).to be false
  end

  it ".signups_open? reflects the toggle" do
    AppSetting.current.update!(signups_open: true)
    expect(AppSetting.signups_open?).to be true
  end

  it "reports whether a GitHub App has been registered" do
    setting = AppSetting.current
    expect(setting.github_app_registered?).to be false

    setting.update!(github_app_id: 123)
    expect(setting.github_app_registered?).to be true
    expect(AppSetting.github_app_registered?).to be true
  end

  it "stores GitHub App ids beyond 32-bit integer range" do
    setting = AppSetting.current

    setting.update!(github_app_id: 9_876_543_210)

    expect(setting.reload.github_app_id).to eq(9_876_543_210)
  end

  it "encrypts GitHub App secrets at rest" do
    setting = AppSetting.current
    setting.update!(
      github_app_private_key_pem: "private-key-pem",
      github_app_webhook_secret: "webhook-secret"
    )

    row = AppSetting.connection.select_one(
      "SELECT github_app_private_key_pem, github_app_webhook_secret FROM app_settings WHERE id = #{setting.id}"
    )
    expect(row["github_app_private_key_pem"]).not_to include("private-key-pem")
    expect(row["github_app_webhook_secret"]).not_to include("webhook-secret")
    expect(setting.reload.github_app_private_key_pem).to eq("private-key-pem")
    expect(setting.github_app_webhook_secret).to eq("webhook-secret")
  end
end

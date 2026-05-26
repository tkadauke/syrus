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

  it ".grade_max_iterations defaults to 5 and reflects the setting" do
    expect(AppSetting.grade_max_iterations).to eq(5)

    AppSetting.current.update!(grade_max_iterations: 2)

    expect(AppSetting.grade_max_iterations).to eq(2)
  end

  it "rejects grade_max_iterations above 10" do
    setting = AppSetting.current
    setting.grade_max_iterations = 11

    expect(setting).not_to be_valid
    expect(setting.errors[:grade_max_iterations]).to include("must be less than or equal to 10")
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
      github_app_private_key_pem: "private-key-pem"
    )

    row = AppSetting.connection.select_one(
      "SELECT github_app_private_key_pem FROM app_settings WHERE id = #{setting.id}"
    )
    expect(row["github_app_private_key_pem"]).not_to include("private-key-pem")
    expect(setting.reload.github_app_private_key_pem).to eq("private-key-pem")
  end

  it "clears only declared clearable app secrets" do
    setting = AppSetting.current
    setting.update!(telegram_bot_token: "telegram-token", telegram_webhook_secret: "telegram-secret")

    setting.clear_secret!("telegram_bot_token")

    expect(setting.reload.telegram_bot_token).to be_nil
    expect(setting.telegram_webhook_secret).to eq("telegram-secret")
  end

  it "rejects clearing non-secret settings" do
    setting = AppSetting.current

    expect {
      setting.clear_secret!("signups_open")
    }.to raise_error(ArgumentError, "Unknown secret: signups_open")
  end
end

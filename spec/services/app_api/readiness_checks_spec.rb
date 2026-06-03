require "rails_helper"

RSpec.describe AppApi::ReadinessChecks do
  def with_env(vars)
    old_values = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def web_config_check_for(user)
    described_class.new(user).as_json.fetch(:checks).find { |check| check[:key] == "web_config" }
  end

  before do
    AppSetting.current.update!(polling_paused: false, runs_paused: false)
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "passes web config readiness without RAILS_MASTER_KEY when Active Record encryption works" do
    user = Factories.user

    with_env("RAILS_MASTER_KEY" => nil) do
      expect(web_config_check_for(user)).to include(
        status: "ok",
        message: "Rails booted and the primary database connection is available."
      )
    end
  end

  it "reports encryption remediation when Active Record encryption cannot be used" do
    user = Factories.user
    allow(ActiveRecord::Encryption.encryptor).to receive(:encrypt)
      .and_raise(ActiveRecord::Encryption::Errors::Configuration, "missing key")

    check = web_config_check_for(user)

    expect(check).to include(
      status: "error",
      message: "Rails is running, but Active Record encryption is not configured in the web environment.",
      remediation: "Set RAILS_MASTER_KEY or provide ACTIVE_RECORD_ENCRYPTION_* environment variables on every web and worker process."
    )
  end
end

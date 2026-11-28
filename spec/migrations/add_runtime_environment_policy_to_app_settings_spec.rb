require "rails_helper"
require Rails.root.join("db/migrate/20261128181148_add_runtime_environment_policy_to_app_settings")

RSpec.describe AddRuntimeEnvironmentPolicyToAppSettings do
  it "is restart-safe in both directions" do
    migration = described_class.new
    expect { 2.times { migration.migrate(:up) } }.not_to raise_error
    expect(ActiveRecord::Base.connection.column_exists?(:app_settings, :runtime_environment_policy, :json)).to be(true)
    expect { 2.times { migration.migrate(:down) } }.not_to raise_error
  ensure
    migration&.migrate(:up)
    AppSetting.reset_column_information
  end
end

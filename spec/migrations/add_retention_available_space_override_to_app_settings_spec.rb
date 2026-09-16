require "rails_helper"
require Rails.root.join("db/migrate/20260916153450_add_retention_available_space_override_to_app_settings")

RSpec.describe AddRetentionAvailableSpaceOverrideToAppSettings, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:column) { :retention_available_space_override_gb }

  it "adds the column with a 0 (unset) default" do
    expect(connection.column_exists?(:app_settings, column)).to eq(true)
    expect(AppSetting.new.public_send(column)).to eq(0)
  end

  it "is idempotent when run more than once" do
    expect {
      migration.up
      migration.up
    }.not_to raise_error

    expect(connection.column_exists?(:app_settings, column)).to eq(true)
  end

  it "has a down migration that removes the column" do
    migration.up
    migration.down
    connection.schema_cache.clear!

    expect(connection.column_exists?(:app_settings, column)).to eq(false)
  ensure
    migration.up
    connection.schema_cache.clear!
    AppSetting.reset_column_information
  end
end

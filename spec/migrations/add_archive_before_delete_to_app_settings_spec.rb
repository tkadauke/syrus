require "rails_helper"
require Rails.root.join("db/migrate/20260917161055_add_archive_before_delete_to_app_settings")
require Rails.root.join("db/migrate/20261028143228_create_retention_policy_settings")

RSpec.describe AddArchiveBeforeDeleteToAppSettings, :ci_only do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  around do |example|
    current_migration = CreateRetentionPolicySettings.new
    current_migration.migrate(:down)
    connection.schema_cache.clear!
    AppSetting.reset_column_information
    example.run
  ensure
    current_migration.migrate(:up) unless connection.table_exists?(:retention_policy_settings)
    connection.schema_cache.clear!
    AppSetting.reset_column_information
  end

  it "adds every archive-before-delete column, defaulting to false" do
    described_class::COLUMNS.each do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(true)
    end

    setting = AppSetting.new
    described_class::COLUMNS.each do |column|
      expect(setting.public_send(column)).to eq(false)
    end
  end

  it "is idempotent when run more than once" do
    expect {
      migration.up
      migration.up
    }.not_to raise_error

    described_class::COLUMNS.each do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(true)
    end
  end

  it "has a down migration that removes the columns" do
    migration.up
    migration.down
    connection.schema_cache.clear!

    described_class::COLUMNS.each do |column|
      expect(connection.column_exists?(:app_settings, column)).to eq(false)
    end
  ensure
    # Restore schema state for any example that runs after this one in the
    # same process (down drops columns the rest of the suite expects).
    migration.up
    connection.schema_cache.clear!
    AppSetting.reset_column_information
  end
end
